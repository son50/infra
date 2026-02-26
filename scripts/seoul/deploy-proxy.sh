#!/bin/bash

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
ENV=${1:?"환경을 지정하세요 (prd/dev)"}
source "$SCRIPT_DIR/../../envs/.env.${ENV}"

echo "--- [Step 3] RDS Proxy 배포 시작 ($REGION) ---"

# 1. data-infra 스택에서 필요한 정보 추출
echo "기존 스택에서 정보 추출 중..."

VPC_ID=$(aws cloudformation describe-stacks \
  --stack-name $DATA_STACK_NAME \
  --region $REGION \
  --query "Stacks[0].Parameters[?ParameterKey=='VpcId'].ParameterValue" \
  --output text)

DB_SECURITY_GROUP=$(aws cloudformation describe-stack-resources \
  --stack-name $DATA_STACK_NAME \
  --region $REGION \
  --logical-resource-id DBSecurityGroup \
  --query "StackResources[0].PhysicalResourceId" \
  --output text)

DB_CLUSTER_ID=$(aws cloudformation describe-stack-resources \
  --stack-name $DATA_STACK_NAME \
  --region $REGION \
  --logical-resource-id AuroraCluster \
  --query "StackResources[0].PhysicalResourceId" \
  --output text)

# data-infra 스택에서 Secrets Manager ARN 가져오기
DB_SECRET_ARN=$(aws cloudformation describe-stacks \
  --stack-name $DATA_STACK_NAME \
  --region $REGION \
  --query "Stacks[0].Outputs[?OutputKey=='DBSecretArn'].OutputValue" \
  --output text)

# 프라이빗 서브넷만 필터링
ALL_SUBNETS=$(aws ec2 describe-subnets --region $REGION \
  --filters "Name=vpc-id,Values=$VPC_ID" \
  --query "Subnets[*].SubnetId" --output text)

PRIVATE_SUBNETS=""
for SUBNET_ID in $ALL_SUBNETS; do
  RT_ID=$(aws ec2 describe-route-tables --region $REGION \
    --filters "Name=association.subnet-id,Values=$SUBNET_ID" \
    --query "RouteTables[0].RouteTableId" --output text 2>/dev/null)

  if [ -z "$RT_ID" ] || [ "$RT_ID" == "None" ]; then
    RT_ID=$(aws ec2 describe-route-tables --region $REGION \
      --filters "Name=vpc-id,Values=$VPC_ID" "Name=association.main,Values=true" \
      --query "RouteTables[0].RouteTableId" --output text)
  fi

  HAS_IGW=$(aws ec2 describe-route-tables --region $REGION \
    --route-table-ids $RT_ID \
    --query "RouteTables[0].Routes[?DestinationCidrBlock=='0.0.0.0/0' && GatewayId!=null && starts_with(GatewayId,'igw-')]" \
    --output text)

  if [ -z "$HAS_IGW" ] || [ "$HAS_IGW" == "None" ]; then
    if [ -z "$PRIVATE_SUBNETS" ]; then
      PRIVATE_SUBNETS="$SUBNET_ID"
    else
      PRIVATE_SUBNETS="$PRIVATE_SUBNETS,$SUBNET_ID"
    fi
  fi
done

SUBNETS=$PRIVATE_SUBNETS

if [ -z "$SUBNETS" ]; then
  echo "❌ 프라이빗 서브넷을 찾을 수 없습니다."
  exit 1
fi

echo "VPC: $VPC_ID"
echo "DB Security Group: $DB_SECURITY_GROUP"
echo "DB Cluster: $DB_CLUSTER_ID"
echo "DB Secret ARN: $DB_SECRET_ARN"
echo "Private Subnets: $SUBNETS"

# 2. RDS Proxy 스택 배포
echo ""
echo "RDS Proxy 스택 배포 중..."

aws cloudformation deploy \
  --stack-name $PROXY_STACK_NAME \
  --template-file $SCRIPT_DIR/../../base/rds-proxy.yaml \
  --parameter-overrides \
    DBClusterIdentifier=$DB_CLUSTER_ID \
    VpcId=$VPC_ID \
    SubnetIds="$SUBNETS" \
    DBSecurityGroup=$DB_SECURITY_GROUP \
    DBSecretArn=$DB_SECRET_ARN \
  --capabilities CAPABILITY_NAMED_IAM \
  --region $REGION

if [ $? -ne 0 ]; then
  echo ""
  echo "❌ RDS Proxy 배포 실패."
  echo "에러 로그:"
  aws cloudformation describe-stack-events \
    --stack-name $PROXY_STACK_NAME \
    --region $REGION \
    --max-items 5 \
    --query 'StackEvents[?ResourceStatus==`CREATE_FAILED`].[LogicalResourceId,ResourceStatusReason]' \
    --output table
  exit 1
fi

echo ""
echo "✅ RDS Proxy 배포 완료!"
echo ""

# 3. Proxy Endpoint 출력
PROXY_ENDPOINT=$(aws cloudformation describe-stacks \
  --stack-name $PROXY_STACK_NAME \
  --region $REGION \
  --query "Stacks[0].Outputs[?OutputKey=='ProxyEndpoint'].OutputValue" \
  --output text)

echo "📌 RDS Proxy Endpoint: $PROXY_ENDPOINT"
echo ""
echo "다음 단계: 이 엔드포인트를 K8s Secret에 저장하세요."