#!/bin/bash

set -e

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
ENV=${1:?"환경을 지정하세요 (prd/dev)"}
source "$SCRIPT_DIR/../../envs/.env.${ENV}"


echo "=========================================="
echo "⚠️  Aurora 복원 스크립트 (비상용)"
echo "=========================================="
echo ""

# 1. 복원 방식 선택
echo "복원 방식을 선택하세요:"
echo "  1) 시점 복원 (Point-in-Time Recovery) - 특정 시각으로 복원"
echo "  2) 스냅샷 복원 - AWS Backup 스냅샷에서 복원"
echo "  3) DR 리전 복원 - $DR_REGION 백업에서 복원 (prod만)"
echo ""
read -p "선택 (1/2/3): " RESTORE_TYPE

case $RESTORE_TYPE in

  # ============================================================
  # 시점 복원 (PITR)
  # ============================================================
  1)
    echo ""
    echo "=== 시점 복원 (PITR) ==="

    # 복원 가능 시간 범위 조회
    CLUSTER_ID=$(aws cloudformation describe-stack-resources \
      --stack-name $DATA_STACK_NAME \
      --region $REGION \
      --logical-resource-id AuroraCluster \
      --query "StackResources[0].PhysicalResourceId" \
      --output text)

    EARLIEST=$(aws rds describe-db-clusters \
      --db-cluster-identifier $CLUSTER_ID \
      --region $REGION \
      --query "DBClusters[0].EarliestRestorableTime" \
      --output text)

    LATEST=$(aws rds describe-db-clusters \
      --db-cluster-identifier $CLUSTER_ID \
      --region $REGION \
      --query "DBClusters[0].LatestRestorableTime" \
      --output text)

    echo "복원 가능 범위: $EARLIEST ~ $LATEST"
    echo ""
    read -p "복원 시점 (예: 2025-02-11T03:00:00Z): " RESTORE_TIME

    RESTORED_CLUSTER="${CLUSTER_ID}-restored-$(date +%Y%m%d%H%M)"

    echo ""
    echo "복원 중... (10-20분 소요)"

    aws rds restore-db-cluster-to-point-in-time \
      --source-db-cluster-identifier $CLUSTER_ID \
      --db-cluster-identifier $RESTORED_CLUSTER \
      --restore-to-time $RESTORE_TIME \
      --region $REGION

    echo "✅ 복원된 클러스터: $RESTORED_CLUSTER"
    ;;

  # ============================================================
  # 스냅샷 복원
  # ============================================================
  2)
    echo ""
    echo "=== 스냅샷 복원 ==="

    # 최근 복구 지점 5개 조회
    echo "최근 복구 지점:"
    aws backup list-recovery-points-by-backup-vault \
      --backup-vault-name "${BACKUP_VAULT_NAME}" \
      --region $REGION \
      --max-results 5 \
      --query "RecoveryPoints[*].[RecoveryPointArn,CreationDate,Status]" \
      --output table

    echo ""
    read -p "복원할 Recovery Point ARN: " RECOVERY_POINT_ARN

    RESTORED_CLUSTER="${AURORA_CLUSTER_NAME}-restored-$(date +%Y%m%d%H%M)"

    # IAM Role ARN
    ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
    RESTORE_ROLE="arn:aws:iam::${ACCOUNT_ID}:role/${ENVIRONMENT}-oy-backup-role-01"

    echo ""
    echo "복원 중... (10-20분 소요)"

    aws backup start-restore-job \
      --recovery-point-arn $RECOVERY_POINT_ARN \
      --iam-role-arn $RESTORE_ROLE \
      --metadata "{\"DBClusterIdentifier\":\"${RESTORED_CLUSTER}\"}" \
      --region $REGION

    echo "✅ 복원 작업 시작: $RESTORED_CLUSTER"
    ;;

  # ============================================================
  # DR 리전 복원
  # ============================================================
  3)
    if [ "$ENVIRONMENT" != "prod" ]; then
      echo "❌ DR 리전 복원은 prod 환경에서만 가능합니다."
      exit 1
    fi

    echo ""
    echo "=== DR 리전 ($DR_REGION) 복원 ==="

    echo "DR 리전 복구 지점:"
    aws backup list-recovery-points-by-backup-vault \
      --backup-vault-name "${BACKUP_VAULT_NAME}-dr" \
      --region $DR_REGION \
      --max-results 5 \
      --query "RecoveryPoints[*].[RecoveryPointArn,CreationDate,Status]" \
      --output table

    echo ""
    read -p "복원할 Recovery Point ARN: " RECOVERY_POINT_ARN

    RESTORED_CLUSTER="${DR_CLUSTER_NAME}-restored-$(date +%Y%m%d%H%M)"

    ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
    RESTORE_ROLE="arn:aws:iam::${ACCOUNT_ID}:role/${ENVIRONMENT}-oy-backup-role-01"

    echo ""
    echo "DR 리전에서 복원 중... (15-30분 소요)"

    aws backup start-restore-job \
      --recovery-point-arn $RECOVERY_POINT_ARN \
      --iam-role-arn $RESTORE_ROLE \
      --metadata "{\"DBClusterIdentifier\":\"${RESTORED_CLUSTER}\"}" \
      --region $DR_REGION

    echo "✅ DR 복원 작업 시작: $RESTORED_CLUSTER ($DR_REGION)"
    ;;

  *)
    echo "❌ 잘못된 선택입니다."
    exit 1
    ;;
esac

echo ""
echo "=========================================="
echo "📌 다음 단계"
echo "=========================================="
echo ""
echo "1. 복원 상태 확인:"
echo "   aws rds describe-db-clusters --db-cluster-identifier <복원된 클러스터ID> --region $REGION"
echo ""
echo "2. 복원된 클러스터에 인스턴스 생성:"
echo "   aws rds create-db-instance \\"
echo "     --db-instance-identifier <복원된 클러스터ID>-writer \\"
echo "     --db-cluster-identifier <복원된 클러스터ID> \\"
echo "     --db-instance-class db.t4g.medium \\"
echo "     --engine aurora-postgresql"
echo ""
echo "3. K8s Secret을 새 엔드포인트로 업데이트:"
echo "   infra-repo/scripts/create-k8s-secrets.sh 수정 후 실행"
