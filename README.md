# infra

AWS 기반 인프라(IaC/배포 스크립트/클러스터 매니페스트) 모음입니다.
이 폴더는 크게 **CloudFormation(데이터·백업·DR·프록시)** + **Terraform(EKS/VPC/관측 스택)** + **Kubernetes 매니페스트(앱·오토스케일·Karpenter)** 로 구성됩니다.

## 구성 요약

- **CloudFormation 템플릿 (`base/`)**
  - `data-infra.yaml`: Aurora PostgreSQL(Writer 1 + Reader AutoScaling) + Redis 생성, DB 비밀번호는 Secrets Manager에서 자동 생성
  - `rds-proxy.yaml`: Aurora 연결용 RDS Proxy(Secrets Manager 기반) + Target Group
  - `backup-policy.yaml`: AWS Backup 일/주/월 스케줄 + (prod) 주간 백업 Cross-Region Copy
  - `global-database.yaml`: Aurora Global Database의 Secondary(도쿄) 클러스터(Pilot Light, Reader 1)
  - `dr-failover-infra.yaml`: 장애 시 도쿄에 Redis + RDS Proxy를 추가로 생성하는 스택

- **GitLab CI (`.gitlab-ci.yml`)**
  - `base/**` 변경 시: CloudFormation 템플릿 `validate-template` 수행
  - `develop` 브랜치: `deploy-data` → `deploy-proxy` → `create-secrets` → `setup-backup` 자동 수행
  - `main` 브랜치: 동일 플로우를 **manual** 승인으로 수행 + `setup-dr`(pilot light) 포함

- **운영 스크립트 (`scripts/`)**
  - `scripts/seoul/deploy-data.sh`: 서울 리전에서 data-infra 스택 배포(프라이빗 서브넷 자동 추출)
  - `scripts/seoul/deploy-proxy.sh`: data-infra 출력/리소스를 읽어 RDS Proxy 스택 배포
  - `scripts/seoul/create-k8s-secrets.sh`: DB/Redis/JWT 등 K8s Secret 생성(프록시/캐시 사용 여부 플래그 지원)
  - `scripts/backup/setup-backup.sh`: Aurora 자동 백업 보관기간 설정 + AWS Backup 스택 배포
  - `scripts/backup/restore.sh`: 비상용 복원(PITR/스냅샷/DR 리전) 가이드형 스크립트
  - `scripts/dr/setup-pilot-light.sh`: Global DB 생성 + 도쿄 Secondary Cluster 배포
  - `scripts/dr/failover.sh`: 서울→도쿄 DR 전환(도쿄 승격 + Secret 복제 + 도쿄 Redis/Proxy 배포 + 도쿄 EKS Secret 생성)
  - `scripts/dr/failback.sh`: 도쿄→서울 복귀 체크리스트(대부분 수동 권장)
  - `scripts/k8s/deploy-apps.sh`: 앱 매니페스트 일괄 적용(확인 프롬프트 포함)
  - `scripts/k8s/cleanup-apps.sh`: 앱 리소스 일괄 삭제(확인 프롬프트 포함)

- **Kubernetes 매니페스트 (`k8s/`)**
  - `k8s/apps/**`: `critical-api`, `sub-api(basic/ai)`, `worker` 배포/서비스/PDB/KEDA ScaledObject
  - `k8s/apps/common/*`: 공통 ConfigMap, KEDA auth, Ingress(ALB)
  - `k8s/karpenter/**`: NodePool/NodeClass, 테스트 리소스, 버전 정보
  - `k8s/pause-pod/**`: (옵션) 워크로드 워밍업/우선순위 관련 리소스

- **Terraform (`terrafrom_code/`)** *(디렉터리명이 `terraform_code`가 아니라 `terrafrom_code` 입니다)*
  - VPC: `terraform-aws-modules/vpc/aws` 모듈 기반
  - (추정) EKS: `module.eks` 출력(클러스터 endpoint/CA)을 기반으로 k8s/helm provider 구성
  - 관측 스택(Helm): Grafana/Loki/Prometheus/Tempo/Otel Collector (`observability_helm.tf`, `helm_values/**`)
  - `outputs.tf`: `kubectl` 설정 커맨드, Grafana 포트포워딩/비밀번호 조회 커맨드 출력

## 사전 준비

- **도구**
  - AWS CLI(필수), `kubectl`, `jq`
  - Terraform(필요 시), Helm provider는 Terraform이 설치되어 있어야 합니다
  - (CI) GitLab Runner 이미지에서 `aws`, `kubectl`, `jq`를 설치해 사용합니다

- **AWS 권한**
  - CloudFormation/RDS/SecretsManager/EKS/EC2/Backup/IAM(Proxy/Backup Role 생성) 권한 필요

## 환경변수/설정 파일

이 repo에는 `envs/.env.*` 파일이 커밋되지 않도록 설정되어 있습니다(`.gitignore`).
대신 아래 스크립트들이 `infra/envs/.env.<env>` 파일을 `source` 하도록 되어 있으니, 로컬/CI에서 반드시 준비해야 합니다.

### `infra/envs/.env.<env>`에 필요한 대표 변수(스크립트 기준)

아래는 스크립트에서 참조되는 키들입니다(환경에 따라 일부만 필요).

- **공통**
  - `REGION`: Primary 리전(예: `ap-northeast-2`)
  - `ENVIRONMENT`: `dev|staging|prod` 등(CloudFormation Parameter에 전달)
  - `CLUSTER_NAME`: 서울 EKS 클러스터 이름
  - `NAMESPACE`: K8s 네임스페이스

- **CloudFormation 스택명**
  - `DATA_STACK_NAME`: `base/data-infra.yaml` 배포 스택명
  - `PROXY_STACK_NAME`: `base/rds-proxy.yaml` 배포 스택명
  - `BACKUP_STACK_NAME`: `base/backup-policy.yaml` 배포 스택명
  - `BACKUP_VAULT_NAME`: Backup Vault prefix(예: `oy-backup-vault-prod`)

- **DB/Secret**
  - `DB_SECRET_ID`: Secrets Manager Secret ID(예: `oy-db-prd-secret`)

- **DR (Pilot Light/Failover)**
  - `DR_REGION`: DR 리전(예: `ap-northeast-1`)
  - `DR_EKS_CLUSTER`: 도쿄 EKS 클러스터 이름
  - `GLOBAL_CLUSTER_ID`: Aurora Global Cluster Identifier
  - `DR_STACK_NAME`: `base/global-database.yaml` 배포 스택명
  - `DR_CLUSTER_ID`: 도쿄 Aurora Cluster ID(승격 대상)
  - `DR_FAILOVER_STACK`: `base/dr-failover-infra.yaml` 배포 스택명

## 실행 플로우(운영 관점)

### 1) (서울) 데이터 인프라 배포

```bash
./scripts/seoul/deploy-data.sh dev   # 또는 prd
```

이 단계에서 다음이 생성됩니다.
- Aurora PostgreSQL Cluster(Writer 1) + Reader AutoScaling(1~5, CPU 70%)
- Redis(기본 1노드)
- DB 비밀번호는 Secrets Manager에서 자동 생성

### 2) (서울) RDS Proxy 배포

```bash
./scripts/seoul/deploy-proxy.sh dev  # 또는 prd
```

`data-infra` 스택에서 VPC/SG/Cluster/Secret 정보를 조회해 Proxy를 생성합니다(IAM Role 생성 포함).

### 3) (서울) K8s Secret 생성(애플리케이션 연결 정보)

```bash
./scripts/seoul/create-k8s-secrets.sh dev   # 또는 prd
```

- 생성되는 Secret 예시: `db-credentials`, `redis-credentials`, `jwt-credentials` 등
- `.env`의 `ENABLE_PROXY`, `ENABLE_CACHE` 값에 따라 Proxy/Redis 사용 흐름이 달라집니다.

### 4) (서울) 백업 정책 설정(최초 1회)

```bash
./scripts/backup/setup-backup.sh dev  # 또는 prd
```

- Aurora 자동 백업 보관기간 설정
- AWS Backup Plan: 일/주/월 백업 스케줄
- prod 환경이면 주간 백업을 DR 리전으로 복사하도록 구성

### 5) (K8s) 앱 배포/정리

```bash
./scripts/k8s/deploy-apps.sh
./scripts/k8s/cleanup-apps.sh
```

`k8s/apps/**`에 정의된 서비스/디플로이먼트/KEDA 리소스와 `Ingress(ALB)`를 적용합니다.

## DR 운영

### Pilot Light(도쿄 Secondary) 초기 세팅

```bash
./scripts/dr/setup-pilot-light.sh prd
```

- 서울 Aurora를 Source로 Global DB 생성(없으면 생성)
- 도쿄에 Secondary Cluster(Reader 1) 배포

### Failover(서울 → 도쿄 전환)

```bash
./scripts/dr/failover.sh prd
```

스크립트 동작(요약):
- 도쿄 Aurora를 Global DB에서 분리하여 Primary로 승격
- DB Secret을 도쿄 리전에 복제(서울 접근 불가 시 수동 입력 경로 제공)
- 도쿄에 Redis + RDS Proxy 스택 생성
- 도쿄 EKS에 `db-credentials`/`redis-credentials`/`jwt-credentials` 생성
- 이후 **앱 재배포** 및 **Route53 DNS 전환**은 안내대로 별도 수행

### Failback(도쿄 → 서울 복귀)

`scripts/dr/failback.sh`는 자동화가 아니라 체크리스트/가이드 중심입니다.
Global Database 재구성은 AWS 콘솔에서 수동 진행을 권장합니다.

## Terraform 사용(클러스터/VPC/관측)

`terrafrom_code/`는 VPC/EKS 및 관측(Helm) 스택을 Terraform으로 구성합니다.

```bash
cd terrafrom_code
terraform init
terraform plan
terraform apply
```

- `outputs.tf`의 `configure_kubectl` 값을 따라 `kubeconfig`를 설정할 수 있습니다.
- Grafana 접근은 `grafana_port_forward` 출력 커맨드를 사용합니다.

## 주의사항

- **비밀정보 커밋 금지**: `envs/.env.*`, `terraform.tfvars`는 로컬/CI에서만 관리하세요.
- **리전/환경 혼동 주의**: DR 스크립트는 `REGION`/`DR_REGION` 및 EKS 클러스터 이름이 정확해야 합니다.
- **Ingress 인증서/도메인**: `k8s/apps/common/api-critical-ingress.yaml`에 ACM 인증서 ARN/Host가 하드코딩되어 있으니, 환경별로 분리 관리가 필요할 수 있습니다.

