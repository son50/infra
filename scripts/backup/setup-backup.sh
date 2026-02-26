#!/bin/bash

set -e

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
ENV=${1:?"환경을 지정하세요 (prd/dev)"}
source "$SCRIPT_DIR/../../envs/.env.${ENV}"


echo "=========================================="
echo "AWS Backup 정책 배포 (최초 1회)"
echo "=========================================="
echo ""
echo "환경: $ENVIRONMENT"
echo "리전: $REGION"
echo "DR 리전: $DR_REGION"
echo ""

# 1. Aurora 클러스터 ARN 추출
echo "=== Step 1: Aurora 클러스터 정보 추출 ==="

CLUSTER_ID=$(aws cloudformation describe-stack-resources \
  --stack-name $DATA_STACK_NAME \
  --region $REGION \
  --logical-resource-id AuroraCluster \
  --query "StackResources[0].PhysicalResourceId" \
  --output text)

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
CLUSTER_ARN="arn:aws:rds:${REGION}:${ACCOUNT_ID}:cluster:${CLUSTER_ID}"

echo "✅ Aurora Cluster: $CLUSTER_ID"
echo "✅ Aurora ARN: $CLUSTER_ARN"

# 2. prod 환경이면 DR 리전에 Backup Vault 생성
if [ "$ENVIRONMENT" == "prod" ]; then
  echo ""
  echo "=== Step 2: DR 리전 Backup Vault 생성 ==="
  aws backup create-backup-vault \
    --backup-vault-name "${BACKUP_VAULT_NAME}-dr" \
    --region $DR_REGION 2>/dev/null || echo "✅ DR Vault 이미 존재합니다"
fi

# 3. Aurora 자동 백업 보관 기간 설정
echo ""
echo "=== Step 3: Aurora 자동 백업 보관 기간 설정 ==="

if [ "$ENVIRONMENT" == "prod" ]; then
  RETENTION_DAYS=35
elif [ "$ENVIRONMENT" == "staging" ]; then
  RETENTION_DAYS=14
else
  RETENTION_DAYS=7
fi

aws rds modify-db-cluster \
  --db-cluster-identifier $CLUSTER_ID \
  --backup-retention-period $RETENTION_DAYS \
  --preferred-backup-window "18:00-19:00" \
  --apply-immediately \
  --region $REGION

echo "✅ Aurora 자동 백업: ${RETENTION_DAYS}일 보관, 매일 KST 03:00~04:00"

# 4. AWS Backup 정책 배포
echo ""
echo "=== Step 4: AWS Backup 정책 배포 ==="

aws cloudformation deploy \
  --stack-name $BACKUP_STACK_NAME \
  --template-file $SCRIPT_DIR/../../base/backup-policy.yaml \
  --parameter-overrides \
    Environment=$ENVIRONMENT \
    AuroraClusterArn=$CLUSTER_ARN \
    DRRegion=$DR_REGION \
  --capabilities CAPABILITY_NAMED_IAM \
  --region $REGION

echo ""
echo "=========================================="
echo "✅ 백업 정책 배포 완료!"
echo "=========================================="
echo ""
echo "📌 백업 스케줄:"
echo "  일일: 매일 KST 03:00 (보관 7일)"
echo "  주간: 매주 일요일 KST 04:00 (보관 30일)"
echo "  월간: 매월 1일 KST 05:00 (보관 365일)"
if [ "$ENVIRONMENT" == "prod" ]; then
  echo "  DR: 주간 백업 → $DR_REGION 복사 (보관 30일)"
fi
echo ""
echo "📌 Aurora 자동 백업: ${RETENTION_DAYS}일 보관"
echo ""
echo "백업 상태 확인: aws backup list-backup-jobs --by-state COMPLETED --region $REGION"
