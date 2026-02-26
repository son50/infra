#!/bin/bash

set -e

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
ROOT_DIR="$( cd "${SCRIPT_DIR}/../.." &> /dev/null && pwd )"

echo "=========================================="
echo "K8s 앱 리소스 배포 (critical / sub / ai / worker)"
echo "=========================================="
echo ""

echo "현재 kubectl 컨텍스트:"
kubectl config current-context
echo ""

read -p "위 클러스터에 배포합니다. 계속할까요? (yes 입력): " CONFIRM
if [ "$CONFIRM" != "yes" ]; then
  echo "취소되었습니다."
  exit 1
fi

echo ""
echo "=== Step 1: 공통 ConfigMap / KEDA Auth 적용 ==="
kubectl apply -f "${ROOT_DIR}/k8s/apps/common/configmap.yaml"
kubectl apply -f "${ROOT_DIR}/k8s/apps/common/keda-auth.yaml"


# echo ""
# echo "=== Step 2: pause-pod 배포 ==="
# kubectl apply -f "${ROOT_DIR}/k8s/pause-pod/priority-class.yaml"
# kubectl apply -f "${ROOT_DIR}/k8s/pause-pod/critical-api/pause-deployment.yaml"
# ## kubectl apply -f "${ROOT_DIR}/k8s/pause-pod/sub-api/pause-deployment.yaml"
# # kubectl apply -f "${ROOT_DIR}/k8s/pause-pod/worker-api/pause-deployment.yaml"


echo ""
echo "=== Step 3: Critical API 배포 ==="
kubectl apply -f "${ROOT_DIR}/k8s/apps/critical-api/api-critical-deployment.yaml"
kubectl apply -f "${ROOT_DIR}/k8s/apps/critical-api/api-critical-service.yaml"
kubectl apply -f "${ROOT_DIR}/k8s/apps/critical-api/api-critical-pdb.yaml"
kubectl apply -f "${ROOT_DIR}/k8s/apps/critical-api/api-critical-scaledobject-keda.yaml"


echo ""
echo "=== Step 4: Critical AI Web Server API (AI 웹 서버) 배포 ==="
kubectl apply -f "${ROOT_DIR}/k8s/apps/critical-api/ai-web-server/api-critical-ai-deployment.yaml"
kubectl apply -f "${ROOT_DIR}/k8s/apps/critical-api/ai-web-server/api-critical-ai-service.yaml"
kubectl apply -f "${ROOT_DIR}/k8s/apps/critical-api/ai-web-server/api-critical-ai-pdb.yaml"
kubectl apply -f "${ROOT_DIR}/k8s/apps/critical-api/ai-web-server/api-critical-ai-scaledobject-keda.yaml"

echo ""
echo "=== Step 5: Sub API (기본 조회) 배포 ==="
kubectl apply -f "${ROOT_DIR}/k8s/apps/sub-api/basic/api-sub-deployment.yaml"
kubectl apply -f "${ROOT_DIR}/k8s/apps/sub-api/basic/api-sub-service.yaml"
kubectl apply -f "${ROOT_DIR}/k8s/apps/sub-api/basic/api-sub-pdb.yaml"
kubectl apply -f "${ROOT_DIR}/k8s/apps/sub-api/basic/api-sub-scaledobject-keda.yaml"

echo ""
echo "=== Step 6: Sub AI API (챗봇) 배포 ==="
kubectl apply -f "${ROOT_DIR}/k8s/apps/sub-api/ai/api-sub-ai-deployment.yaml"
kubectl apply -f "${ROOT_DIR}/k8s/apps/sub-api/ai/api-sub-ai-service.yaml"
kubectl apply -f "${ROOT_DIR}/k8s/apps/sub-api/ai/api-sub-ai-pdb.yaml"
kubectl apply -f "${ROOT_DIR}/k8s/apps/sub-api/ai/api-sub-ai-scaledobject-keda.yaml"


echo ""
echo "=== Step 7: Worker (배치/KEDA) 배포 ==="
kubectl apply -f "${ROOT_DIR}/k8s/apps/worker/worker-deployment.yaml"
kubectl apply -f "${ROOT_DIR}/k8s/apps/worker/worker-pdb.yaml"
kubectl apply -f "${ROOT_DIR}/k8s/apps/worker/worker-scaledobject-keda.yaml"

echo ""
echo "=== Step 8: Ingress (ALB) 적용 ==="
kubectl apply -f "${ROOT_DIR}/k8s/apps/common/api-critical-ingress.yaml"

echo ""
echo "=== Step 9: 배포 완료 확인 ==="
kubectl get deploy,svc,hpa -n default
echo ""
echo "필요 시:"
echo "  kubectl get ingress spring-backend-api-ingress -n default"
echo "로 ALB 주소를 확인하세요."

