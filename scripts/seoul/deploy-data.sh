#!/bin/bash

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
ENV=${1:?"환경을 지정하세요 (prd/dev)"}
source "$SCRIPT_DIR/../../envs/.env.${ENV}"

STACK_NAME=$DATA_STACK_NAME

echo "--- [Step 2] 데이터 인프라 배포 시작 ($REGION) ---"

# 1. EKS에서 VPC ID와 Node SG ID 추출
VPC_ID=$(aws eks describe-cluster --name $CLUSTER_NAME --region $REGION --query "cluster.resourcesVpcConfig.vpcId" --output text)
NODE_SG=$(aws eks describe-cluster --name $CLUSTER_NAME --region $REGION --query "cluster.resourcesVpcConfig.clusterSecurityGroupId" --output text)

# 2. VPC 내의 프라이빗 서브넷만 필터링하여 추출
#    퍼블릭 서브넷 = 라우팅 테이블에 IGW(0.0.0.0/0 → igw-xxx)가 있는 서브넷
#    프라이빗 서브넷 = IGW 라우트가 없는 서브넷
ALL_SUBNETS=$(aws ec2 describe-subnets --region $REGION \
  --filters "Name=vpc-id,Values=$VPC_ID" \
  --query "Subnets[*].SubnetId" --output text)

PRIVATE_SUBNETS=""
for SUBNET_ID in $ALL_SUBNETS; do
  # 서브넷에 연결된 라우팅 테이블 조회
  RT_ID=$(aws ec2 describe-route-tables --region $REGION \
    --filters "Name=association.subnet-id,Values=$SUBNET_ID" \
    --query "RouteTables[0].RouteTableId" --output text 2>/dev/null)

  # 명시적 연결이 없으면 VPC 메인 라우팅 테이블 사용
  if [ -z "$RT_ID" ] || [ "$RT_ID" == "None" ]; then
    RT_ID=$(aws ec2 describe-route-tables --region $REGION \
      --filters "Name=vpc-id,Values=$VPC_ID" "Name=association.main,Values=true" \
      --query "RouteTables[0].RouteTableId" --output text)
  fi

  # IGW로 향하는 0.0.0.0/0 라우트가 있으면 퍼블릭 → 스킵
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
  echo "❌ 프라이빗 서브넷을 찾을 수 없습니다. VPC 구성을 확인하세요."
  exit 1
fi

echo "VPC: $VPC_ID"
echo "Subnets: $SUBNETS"
echo ""
echo "📌 배포 구성:"
echo "  Aurora Writer 1대 + Reader Auto Scaling (1~5대, CPU 70% 기준)"
echo "  Redis 1대 (cache.t4g.micro)"
echo ""

# 3. CloudFormation 스택 배포
aws cloudformation deploy \
  --stack-name $STACK_NAME \
  --template-file $SCRIPT_DIR/../../base/data-infra.yaml \
  --parameter-overrides \
    VpcId=$VPC_ID \
    NodeSecurityGroup=$NODE_SG \
    SubnetIds="$SUBNETS" \
  --region $REGION

echo ""
echo "--- 배포 요청 완료! AWS 콘솔에서 생성을 확인하세요. ---"
