#!/bin/bash

set -e

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
ENV=${1:?"환경을 지정하세요 (prd/dev)"}

echo "=========================================="
echo "디버깅: 현재 환경은 [$ENV] 입니다."

source "$SCRIPT_DIR/../../envs/.env.${ENV}"

# 캐시/프록시 기본값 (env 파일에 없으면 false)
ENABLE_CACHE=${ENABLE_CACHE:-"false"}
ENABLE_PROXY=${ENABLE_PROXY:-"false"}

echo "=========================================="
echo "K8s Secret 생성 스크립트 (최종 수정본)"
echo "=========================================="
echo "  EnableCache: $ENABLE_CACHE"
echo "  EnableProxy: $ENABLE_PROXY"
echo ""

# 1. EKS 연결 및 Namespace 준비
echo "=== Step 1: EKS 연결 및 네임스페이스 준비 ==="
aws --region $REGION eks update-kubeconfig --name $CLUSTER_NAME
kubectl create namespace $NAMESPACE --dry-run=client -o yaml | kubectl apply -f -

# 2. DB 정보 추출
echo "=== Step 2: DB 정보 추출 ==="
DB_PASSWORD=$(aws secretsmanager get-secret-value \
  --secret-id $DB_SECRET_ID \
  --query "SecretString" --output text | jq -r '.password')

if [ "$ENABLE_PROXY" == "true" ]; then
  PROXY_NAME="prd-oy-aurora-cluster-proxy"
  
  # 쓰기용(Primary) Proxy 엔드포인트
  PRIMARY_ENDPOINT=$(aws --region $REGION cloudformation describe-stacks \
    --stack-name $PROXY_STACK_NAME \
    --query "Stacks[0].Outputs[?OutputKey=='ProxyEndpoint'].OutputValue" \
    --output text 2>/dev/null || echo "")

  # 읽기용(Replica) Proxy 엔드포인트 (정확한 프록시 이름으로 조회)
  REPLICA_ENDPOINT=$(aws --region $REGION rds describe-db-proxy-endpoints \
    --db-proxy-name "$PROXY_NAME" \
    --query "DBProxyEndpoints[?TargetRole=='READ_ONLY'].Endpoint" \
    --output text 2>/dev/null || echo "")
  
  echo "✅ RDS Proxy 주소 획득: (RW: $PRIMARY_ENDPOINT / RO: $REPLICA_ENDPOINT)"
else
  # 프록시 미사용 시 직접 연결
  PRIMARY_ENDPOINT=$(aws --region $REGION cloudformation describe-stacks \
    --stack-name $DATA_STACK_NAME \
    --query "Stacks[0].Outputs[?OutputKey=='AuroraWriterEndpoint'].OutputValue" \
    --output text)
  REPLICA_ENDPOINT=$(aws --region $REGION cloudformation describe-stacks \
    --stack-name $DATA_STACK_NAME \
    --query "Stacks[0].Outputs[?OutputKey=='AuroraReaderEndpoint'].OutputValue" \
    --output text)
fi

# 3. K8s Secret 생성 (DB)
echo "=== Step 3: DB Secret 생성 (db-credentials) ==="
kubectl create secret generic db-credentials \
  --from-literal=primary_host=$PRIMARY_ENDPOINT \
  --from-literal=replica_host=$REPLICA_ENDPOINT \
  --from-literal=port=5432 \
  --from-literal=database=postgres \
  --from-literal=username=postgres \
  --from-literal=password=$DB_PASSWORD \
  --namespace=$NAMESPACE \
  --dry-run=client -o yaml | kubectl apply -f -

# 4. Redis 및 Vector Redis 생성 (캐시 활성화 시)
if [ "$ENABLE_CACHE" == "true" ]; then
  echo "=== Step 4: Redis 및 Vector Redis 생성 ==="
  
  # 일반 Redis
  REDIS_ENDPOINT=$(aws --region $REGION cloudformation describe-stacks \
    --stack-name $DATA_STACK_NAME \
    --query "Stacks[0].Outputs[?OutputKey=='RedisPrimaryEndpoint'].OutputValue" \
    --output text)
  kubectl create secret generic redis-credentials \
    --from-literal=host=$REDIS_ENDPOINT \
    --from-literal=port=6379 \
    --namespace=$NAMESPACE \
    --dry-run=client -o yaml | kubectl apply -f -

  # Vector Redis
  VECTOR_REDIS_ENDPOINT=$(aws --region $REGION cloudformation describe-stacks \
    --stack-name $DATA_STACK_NAME \
    --query "Stacks[0].Outputs[?OutputKey=='VectorRedisPrimaryEndpoint'].OutputValue" \
    --output text 2>/dev/null || echo "")

  if [ -n "$VECTOR_REDIS_ENDPOINT" ] && [ "$VECTOR_REDIS_ENDPOINT" != "None" ]; then
    kubectl create secret generic vector-redis-credentials \
      --from-literal=host=$VECTOR_REDIS_ENDPOINT \
      --from-literal=port=6379 \
      --namespace=$NAMESPACE \
      --dry-run=client -o yaml | kubectl apply -f -
    echo "✅ vector-redis-credentials 생성 완료"
  fi
fi

echo "=========================================="
echo "✅ 모든 Secret이 성공적으로 업데이트되었습니다!"
echo "=========================================="