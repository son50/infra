#!/bin/bash

set -e

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
ENV=${1:?"환경을 지정하세요 (prd/dev)"}
source "$SCRIPT_DIR/../../envs/.env.${ENV}"


echo "=========================================="
echo "⚠️  DR 전환 실행 (서울 → 도쿄)"
echo "=========================================="
echo ""
echo "이 작업은 도쿄 리전을 Primary로 전환합니다."
echo ""
read -p "정말 실행하시겠습니까? (yes 입력): " CONFIRM
if [ "$CONFIRM" != "yes" ]; then
  echo "취소되었습니다."
  exit 1
fi

FAILOVER_START=$(date +%s)

# ============================================================
# Step 1: Global Database에서 도쿄 클러스터 분리 + Primary 승격
# ============================================================
echo ""
echo "=== Step 1: 도쿄 Aurora를 Primary로 승격 (약 1-2분) ==="

aws rds remove-from-global-cluster \
  --global-cluster-identifier $GLOBAL_CLUSTER_ID \
  --db-cluster-identifier arn:aws:rds:${DR_REGION}:$(aws sts get-caller-identity --query Account --output text):cluster:${DR_CLUSTER_ID} \
  --region $DR_REGION

echo "승격 대기 중..."
aws rds wait db-cluster-available \
  --db-cluster-identifier $DR_CLUSTER_ID \
  --region $DR_REGION

echo "✅ 도쿄 Aurora가 Primary로 승격됨"

# ============================================================
# Step 2: DB Secret을 도쿄에 복제
# ============================================================
echo ""
echo "=== Step 2: DB Secret 도쿄에 복제 ==="

# 서울 Secret에서 값 가져오기 (서울이 접근 가능한 경우)
DB_SECRET_VALUE=$(aws secretsmanager get-secret-value \
  --secret-id $DB_SECRET_ID \
  --region $REGION \
  --query "SecretString" --output text 2>/dev/null || echo "")

if [ -z "$DB_SECRET_VALUE" ]; then
  echo "⚠️  서울 Secret 접근 불가. 수동으로 DB 비밀번호를 입력하세요."
  read -sp "DB Password: " DB_PASSWORD
  echo
  DB_SECRET_VALUE="{\"username\":\"postgres\",\"password\":\"${DB_PASSWORD}\"}"
fi

# 도쿄에 Secret 생성
aws secretsmanager create-secret \
  --name "${DB_SECRET_ID}-dr" \
  --secret-string "$DB_SECRET_VALUE" \
  --region $DR_REGION 2>/dev/null || \
aws secretsmanager put-secret-value \
  --secret-id "${DB_SECRET_ID}-dr" \
  --secret-string "$DB_SECRET_VALUE" \
  --region $DR_REGION

DR_SECRET_ARN=$(aws secretsmanager describe-secret \
  --secret-id "${DB_SECRET_ID}-dr" \
  --region $DR_REGION \
  --query "ARN" --output text)

echo "✅ Secret 복제 완료: $DR_SECRET_ARN"

# ============================================================
# Step 3: Redis + RDS Proxy 생성 (도쿄)
# ============================================================
echo ""
echo "=== Step 3: Redis + RDS Proxy 배포 (약 5-10분) ==="

# 도쿄 VPC 정보
DR_VPC_ID=$(aws eks describe-cluster \
  --name $DR_EKS_CLUSTER \
  --region $DR_REGION \
  --query "cluster.resourcesVpcConfig.vpcId" \
  --output text)

DR_NODE_SG=$(aws eks describe-cluster \
  --name $DR_EKS_CLUSTER \
  --region $DR_REGION \
  --query "cluster.resourcesVpcConfig.clusterSecurityGroupId" \
  --output text)

# DB Security Group (Global DB 스택에서)
DR_DB_SG=$(aws cloudformation describe-stack-resources \
  --stack-name $DR_STACK_NAME \
  --region $DR_REGION \
  --logical-resource-id DBSecurityGroupTokyo \
  --query "StackResources[0].PhysicalResourceId" \
  --output text)

# 프라이빗 서브넷 필터링
ALL_SUBNETS=$(aws ec2 describe-subnets --region $DR_REGION \
  --filters "Name=vpc-id,Values=$DR_VPC_ID" \
  --query "Subnets[*].SubnetId" --output text)

DR_PRIVATE_SUBNETS=""
for SUBNET_ID in $ALL_SUBNETS; do
  RT_ID=$(aws ec2 describe-route-tables --region $DR_REGION \
    --filters "Name=association.subnet-id,Values=$SUBNET_ID" \
    --query "RouteTables[0].RouteTableId" --output text 2>/dev/null)

  if [ -z "$RT_ID" ] || [ "$RT_ID" == "None" ]; then
    RT_ID=$(aws ec2 describe-route-tables --region $DR_REGION \
      --filters "Name=vpc-id,Values=$DR_VPC_ID" "Name=association.main,Values=true" \
      --query "RouteTables[0].RouteTableId" --output text)
  fi

  HAS_IGW=$(aws ec2 describe-route-tables --region $DR_REGION \
    --route-table-ids $RT_ID \
    --query "RouteTables[0].Routes[?DestinationCidrBlock=='0.0.0.0/0' && GatewayId!=null && starts_with(GatewayId,'igw-')]" \
    --output text)

  if [ -z "$HAS_IGW" ] || [ "$HAS_IGW" == "None" ]; then
    if [ -z "$DR_PRIVATE_SUBNETS" ]; then
      DR_PRIVATE_SUBNETS="$SUBNET_ID"
    else
      DR_PRIVATE_SUBNETS="$DR_PRIVATE_SUBNETS,$SUBNET_ID"
    fi
  fi
done

aws cloudformation deploy \
  --stack-name $DR_FAILOVER_STACK \
  --template-file $SCRIPT_DIR/../../base/dr-failover-infra.yaml \
  --parameter-overrides \
    VpcId=$DR_VPC_ID \
    SubnetIds="$DR_PRIVATE_SUBNETS" \
    DBSecurityGroup=$DR_DB_SG \
    DBClusterIdentifier=$DR_CLUSTER_ID \
    DBSecretArn=$DR_SECRET_ARN \
    NodeSecurityGroup=$DR_NODE_SG \
    Environment=$ENVIRONMENT \
  --capabilities CAPABILITY_NAMED_IAM \
  --region $DR_REGION

# 엔드포인트 추출
DR_PROXY_ENDPOINT=$(aws cloudformation describe-stacks \
  --stack-name $DR_FAILOVER_STACK \
  --region $DR_REGION \
  --query "Stacks[0].Outputs[?OutputKey=='ProxyEndpoint'].OutputValue" \
  --output text)

DR_REDIS_ENDPOINT=$(aws cloudformation describe-stacks \
  --stack-name $DR_FAILOVER_STACK \
  --region $DR_REGION \
  --query "Stacks[0].Outputs[?OutputKey=='RedisEndpoint'].OutputValue" \
  --output text)

echo "✅ DR Proxy: $DR_PROXY_ENDPOINT"
echo "✅ DR Redis: $DR_REDIS_ENDPOINT"

# ============================================================
# Step 4: K8s Secret 생성 (도쿄 EKS)
# ============================================================
echo ""
echo "=== Step 4: 도쿄 EKS에 K8s Secret 생성 ==="

aws eks update-kubeconfig --name $DR_EKS_CLUSTER --region $DR_REGION

kubectl create namespace $NAMESPACE --dry-run=client -o yaml | kubectl apply -f -

DB_PASSWORD=$(echo "$DB_SECRET_VALUE" | jq -r '.password')

kubectl create secret generic db-credentials \
  --from-literal=host=$DR_PROXY_ENDPOINT \
  --from-literal=port=5432 \
  --from-literal=database=postgres \
  --from-literal=username=postgres \
  --from-literal=password=$DB_PASSWORD \
  --namespace=$NAMESPACE \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret generic redis-credentials \
  --from-literal=host=$DR_REDIS_ENDPOINT \
  --from-literal=port=6379 \
  --namespace=$NAMESPACE \
  --dry-run=client -o yaml | kubectl apply -f -

JWT_SECRET_VALUE=${JWT_SECRET:-$(openssl rand -base64 32)}
kubectl create secret generic jwt-credentials \
  --from-literal=secret=$JWT_SECRET_VALUE \
  --namespace=$NAMESPACE \
  --dry-run=client -o yaml | kubectl apply -f -

echo "✅ K8s Secret 생성 완료"

# ============================================================
# Step 5: 완료
# ============================================================
FAILOVER_END=$(date +%s)
FAILOVER_DURATION=$((FAILOVER_END - FAILOVER_START))

echo ""
echo "=========================================="
echo "✅ DR 전환 완료! (소요시간: ${FAILOVER_DURATION}초)"
echo "=========================================="
echo ""
echo "📌 도쿄 엔드포인트:"
echo "  DB Proxy: $DR_PROXY_ENDPOINT"
echo "  Redis:    $DR_REDIS_ENDPOINT"
echo ""
echo "📌 다음 단계:"
echo "  1. 백엔드팀: backend-repo에서 도쿄 EKS로 배포"
echo "     kubectl apply -f k8s/backend-deployment.yaml -n $NAMESPACE"
echo "  2. 프론트팀: frontend-repo에서 도쿄 EKS로 배포"
echo "     kubectl apply -f k8s/frontend-deployment.yaml -n $NAMESPACE"
echo "  3. Route53 DNS를 도쿄 ALB로 전환"
