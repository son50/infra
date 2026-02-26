#!/bin/bash

set -e

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
ENV=${1:?"환경을 지정하세요 (prd/dev)"}
source "$SCRIPT_DIR/../../envs/.env.${ENV}"

SEOUL_CLUSTER_ID=$AURORA_CLUSTER_ID

echo "=========================================="
echo "⚠️  Failback 실행 (도쿄 → 서울 복귀)"
echo "=========================================="
echo ""
echo "서울 리전이 복구된 후 실행하세요."
echo ""
read -p "서울 리전이 정상 복구되었습니까? (yes 입력): " CONFIRM
if [ "$CONFIRM" != "yes" ]; then
  echo "취소되었습니다."
  exit 1
fi

# 1. 서울 Aurora 상태 확인
echo ""
echo "=== Step 1: 서울 Aurora 상태 확인 ==="
SEOUL_STATUS=$(aws rds describe-db-clusters \
  --db-cluster-identifier $SEOUL_CLUSTER_ID \
  --region $REGION \
  --query "DBClusters[0].Status" \
  --output text 2>/dev/null || echo "unavailable")

echo "서울 클러스터 상태: $SEOUL_STATUS"

if [ "$SEOUL_STATUS" != "available" ]; then
  echo "❌ 서울 클러스터가 아직 사용 불가합니다."
  echo "   복구 후 다시 시도하세요."
  exit 1
fi

# 2. Global Database 재구성
echo ""
echo "=== Step 2: Global Database 재구성 ==="
echo ""
echo "Failback 절차:"
echo "  1) 도쿄 데이터를 서울로 복제 (Global Database 재구성)"
echo "  2) 서울을 다시 Primary로 전환"
echo "  3) K8s Secret을 서울 엔드포인트로 복원"
echo "  4) 서울 EKS로 앱 재배포"
echo ""
echo "📌 이 작업은 수동으로 진행하는 것을 권장합니다."
echo "   AWS 콘솔에서 Global Database를 재구성하세요."
echo ""
echo "참고 문서:"
echo "  https://docs.aws.amazon.com/AmazonRDS/latest/AuroraUserGuide/aurora-global-database-disaster-recovery.managed-failover.html"
echo ""

# 3. 안내
echo "=========================================="
echo "📌 Failback 체크리스트"
echo "=========================================="
echo ""
echo "[ ] 서울 Aurora 클러스터 정상 확인"
echo "[ ] Global Database 재구성 (도쿄 → 서울)"
echo "[ ] 서울 RDS Proxy 정상 확인"
echo "[ ] 서울 Redis 정상 확인"
echo "[ ] K8s Secret 서울 엔드포인트로 업데이트"
echo "    → ./scripts/seoul/create-k8s-secrets.sh"
echo "[ ] 서울 EKS에 앱 재배포"
echo "    → backend-repo: ./scripts/deploy-to-eks.sh"
echo "    → frontend-repo: kubectl apply -f k8s/frontend-deployment.yaml"
echo "[ ] Route53 DNS를 서울 ALB로 복귀"
echo "[ ] 도쿄 DR Failover 스택 정리"
echo "    → aws cloudformation delete-stack --stack-name $DR_FAILOVER_STACK --region $DR_REGION"
