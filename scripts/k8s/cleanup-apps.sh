#!/bin/bash

set -e

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
ROOT_DIR="$( cd "${SCRIPT_DIR}/../.." &> /dev/null && pwd )"

echo "=========================================="
echo "K8s 앱 리소스 정리 (critical / sub / ai / worker)"
echo "=========================================="
echo ""

kubectl config current-context
echo ""
read -p "위 클러스터에서 리소스를 삭제합니다. 계속할까요? (yes 입력): " CONFIRM
if [ "$CONFIRM" != "yes" ]; then
  echo "취소되었습니다."
  exit 1
fi

echo ""
echo "=== Step 1: Ingress 제거 ==="
kubectl delete -f "${ROOT_DIR}/k8s/apps/common/api-critical-ingress.yaml" --ignore-not-found

echo ""
echo "=== Step 2: Worker / KEDA 제거 ==="
kubectl delete -f "${ROOT_DIR}/k8s/apps/worker/worker-scaledobject-keda.yaml" --ignore-not-found
kubectl delete -f "${ROOT_DIR}/k8s/apps/worker/worker-pdb.yaml" --ignore-not-found
kubectl delete -f "${ROOT_DIR}/k8s/apps/worker/worker-deployment.yaml" --ignore-not-found


echo ""
echo "=== Step 3: Sub AI API 제거 ==="
kubectl delete -f "${ROOT_DIR}/k8s/apps/sub-api/ai/api-sub-ai-scaledobject-keda.yaml" --ignore-not-found
kubectl delete -f "${ROOT_DIR}/k8s/apps/sub-api/ai/api-sub-ai-service.yaml" --ignore-not-found
kubectl delete -f "${ROOT_DIR}/k8s/apps/sub-api/ai/api-sub-ai-pdb.yaml" --ignore-not-found
kubectl delete -f "${ROOT_DIR}/k8s/apps/sub-api/ai/api-sub-ai-deployment.yaml" --ignore-not-found

echo ""
echo "=== Step 4: Sub API (기본 조회) 제거 ==="
kubectl delete -f "${ROOT_DIR}/k8s/apps/sub-api/basic/api-sub-scaledobject-keda.yaml" --ignore-not-found
kubectl delete -f "${ROOT_DIR}/k8s/apps/sub-api/basic/api-sub-service.yaml" --ignore-not-found
kubectl delete -f "${ROOT_DIR}/k8s/apps/sub-api/basic/api-sub-pdb.yaml" --ignore-not-found
kubectl delete -f "${ROOT_DIR}/k8s/apps/sub-api/basic/api-sub-deployment.yaml" --ignore-not-found


echo ""
echo "=== Step 5: Critical AI Web Server API (AI 웹 서버) 제거 ==="
kubectl delete -f "${ROOT_DIR}/k8s/apps/critical-api/ai-web-server/api-critical-ai-scaledobject-keda.yaml" --ignore-not-found
kubectl delete -f "${ROOT_DIR}/k8s/apps/critical-api/ai-web-server/api-critical-ai-service.yaml" --ignore-not-found
kubectl delete -f "${ROOT_DIR}/k8s/apps/critical-api/ai-web-server/api-critical-ai-pdb.yaml" --ignore-not-found
kubectl delete -f "${ROOT_DIR}/k8s/apps/critical-api/ai-web-server/api-critical-ai-deployment.yaml" --ignore-not-found



echo ""
echo "=== Step 6: Critical API 제거 ==="
kubectl delete -f "${ROOT_DIR}/k8s/apps/critical-api/api-critical-scaledobject-keda.yaml" --ignore-not-found
kubectl delete -f "${ROOT_DIR}/k8s/apps/critical-api/api-critical-service.yaml" --ignore-not-found
kubectl delete -f "${ROOT_DIR}/k8s/apps/critical-api/api-critical-pdb.yaml" --ignore-not-found
kubectl delete -f "${ROOT_DIR}/k8s/apps/critical-api/api-critical-deployment.yaml" --ignore-not-found

# echo ""
# echo "=== Step 7: pause-pod 제거 ==="
# kubectl delete -f "${ROOT_DIR}/k8s/pause-pod/critical-api/pause-deployment.yaml" --ignore-not-found
# ## kubectl delete -f "${ROOT_DIR}/k8s/pause-pod/sub-api/pause-deployment.yaml" --ignore-not-found
# # kubectl delete -f "${ROOT_DIR}/k8s/pause-pod/worker-api/pause-deployment.yaml" --ignore-not-found
# kubectl delete -f "${ROOT_DIR}/k8s/pause-pod/priority-class.yaml" --ignore-not-found


echo ""
echo "=== Step 8: 공통 ConfigMap / KEDA Auth 제거 (원하면 유지 가능) ==="
kubectl delete -f "${ROOT_DIR}/k8s/apps/common/configmap.yaml" --ignore-not-found
kubectl delete -f "${ROOT_DIR}/k8s/apps/common/keda-auth.yaml" --ignore-not-found

echo ""
echo "정리 완료:"
kubectl get deploy,svc,hpa -n default

