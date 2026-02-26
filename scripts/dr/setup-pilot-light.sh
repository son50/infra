#!/bin/bash

set -e

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
ENV=${1:?"환경을 지정하세요 (prd/dev)"}
source "$SCRIPT_DIR/../../envs/.env.${ENV}"


echo "=========================================="
echo "Pilot Light DR 초기 설정"
echo "=========================================="
echo ""
echo "Primary: $REGION (서울)"
echo "DR:      $DR_REGION (도쿄)"
echo ""

# 1. 서울 Aurora 클러스터 정보 추출
echo "=== Step 1: 서울 Aurora 클러스터 정보 ==="

CLUSTER_ID=$(aws cloudformation describe-stack-resources \
  --stack-name $DATA_STACK_NAME \
  --region $REGION \
  --logical-resource-id AuroraCluster \
  --query "StackResources[0].PhysicalResourceId" \
  --output text)

echo "✅ Seoul Cluster: $CLUSTER_ID"

# 2. Global Database 생성 (서울 클러스터를 Primary로)
echo ""
echo "=== Step 2: Global Database 생성 ==="

aws rds create-global-cluster \
  --global-cluster-identifier $GLOBAL_CLUSTER_ID \
  --source-db-cluster-identifier arn:aws:rds:${REGION}:$(aws sts get-caller-identity --query Account --output text):cluster:${CLUSTER_ID} \
  --region $REGION 2>/dev/null || echo "✅ Global Database 이미 존재합니다"

echo "Global Database 생성 대기 중..."
aws rds wait db-cluster-available \
  --db-cluster-identifier $CLUSTER_ID \
  --region $REGION

echo "✅ Global Database: $GLOBAL_CLUSTER_ID"

# 3. 도쿄 VPC/서브넷 정보 추출
echo ""
echo "=== Step 3: 도쿄 EKS 정보 추출 ==="

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

echo "✅ Tokyo VPC: $DR_VPC_ID"
echo "✅ Tokyo Private Subnets: $DR_PRIVATE_SUBNETS"

# 4. 도쿄에 Secondary Cluster 배포
echo ""
echo "=== Step 4: 도쿄 Secondary Cluster 배포 ==="

aws cloudformation deploy \
  --stack-name $DR_STACK_NAME \
  --template-file $SCRIPT_DIR/../../base/global-database.yaml \
  --parameter-overrides \
    GlobalClusterIdentifier=$GLOBAL_CLUSTER_ID \
    SourceClusterIdentifier=$CLUSTER_ID \
    VpcId=$DR_VPC_ID \
    SubnetIds="$DR_PRIVATE_SUBNETS" \
    NodeSecurityGroup=$DR_NODE_SG \
    Environment=$ENVIRONMENT \
  --region $DR_REGION

echo ""
echo "=========================================="
echo "✅ Pilot Light DR 설정 완료!"
echo "=========================================="
echo ""
echo "📌 현재 구성:"
echo "  서울 (Primary): Writer + Auto Scaling Reader"
echo "  도쿄 (DR):      Reader 1대 (실시간 복제)"
echo ""
echo "📌 평소 상태: 도쿄 Reader가 서울 Writer의 데이터를 자동 복제"
echo "📌 장애 시:   ./failover.sh 실행 → 도쿄를 Primary로 전환"
