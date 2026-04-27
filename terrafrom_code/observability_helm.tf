# 관측 스택: Loki, Prometheus, Tempo, Grafana, OpenTelemetry Collector (monitoring 네임스페이스)
# Helm/Kubernetes provider는 EKS 모듈 출력을 사용합니다. AWS CLI가 설치되어 있어야
# exec(eks get-token) 인증이 동작합니다.
#
# cluster_endpoint·CA는 클러스터가 없을 때 plan 출력상 (known after apply)로 남습니다.
# Terraform 1.9+ deferred actions와 최신 kubernetes/helm provider 조합에서는
# 최초에도 plan/apply가 통과하는 경우가 많습니다.
# 구버전 TF이거나 "provider configuration could not be decoded" 류 오류가 나면:
#   terraform apply -target=module.vpc -target=module.eks
# 로 EKS만 먼저 만든 뒤 다시 apply 하세요.

locals {
  observability_namespace = "monitoring"
  helm_chart_versions = {
    loki                    = "6.16.0"
    prometheus            = "25.8.2"
    tempo                   = "1.10.3"
    grafana                 = "8.8.2"
    opentelemetry_collector = "0.104.0"
  }
}

provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name, "--region", var.TargetRegion]
  }
}

provider "helm" {
  kubernetes {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)

    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name, "--region", var.TargetRegion]
    }
  }
}

resource "kubernetes_namespace" "monitoring" {
  metadata {
    name = local.observability_namespace
  }

  depends_on = [module.eks]
}

resource "helm_release" "tempo" {
  name       = "tempo"
  repository = "https://grafana.github.io/helm-charts"
  chart      = "tempo"
  version    = local.helm_chart_versions.tempo

  namespace        = local.observability_namespace
  create_namespace = false

  values = [file("${path.module}/helm_values/tempo-values.yaml")]

  wait    = true
  timeout = 1200

  depends_on = [module.eks, kubernetes_namespace.monitoring]
}

# EBS CSI 애드온 ACTIVE 이후에 잠깐 버퍼 (ebs_csi.tf)
resource "time_sleep" "wait_ebs_csi" {
  create_duration = "60s"
  depends_on      = [aws_eks_addon.ebs_csi_driver]
}

resource "helm_release" "loki" {
  name       = "loki"
  repository = "https://grafana.github.io/helm-charts"
  chart      = "loki"
  version    = local.helm_chart_versions.loki

  namespace        = local.observability_namespace
  create_namespace = false

  values = [file("${path.module}/helm_values/loki-values.yaml")]

  wait    = true
  timeout = 1200

  # t3.small 등 소형 노드에서는 Loki+Prometheus 동시 기동 시 스케줄/이미지 풀에 밀림 → 순차 설치
  depends_on = [
    module.eks,
    kubernetes_namespace.monitoring,
    helm_release.tempo,
    time_sleep.wait_ebs_csi,
    kubernetes_storage_class_v1.ebs_gp3,
  ]
}

resource "helm_release" "prometheus" {
  name       = "prometheus"
  repository = "https://prometheus-community.github.io/helm-charts"
  chart      = "prometheus"
  version    = local.helm_chart_versions.prometheus

  namespace        = local.observability_namespace
  create_namespace = false

  values = [file("${path.module}/helm_values/prometheus-values.yaml")]

  wait    = true
  timeout = 1200

  depends_on = [module.eks, kubernetes_namespace.monitoring, helm_release.loki]
}

resource "helm_release" "grafana" {
  name       = "grafana"
  repository = "https://grafana.github.io/helm-charts"
  chart      = "grafana"
  version    = local.helm_chart_versions.grafana

  namespace        = local.observability_namespace
  create_namespace = false

  values = [file("${path.module}/helm_values/grafana-values.yaml")]

  wait    = true
  timeout = 1200

  depends_on = [
    module.eks,
    kubernetes_namespace.monitoring,
    helm_release.loki,
    helm_release.prometheus,
    helm_release.tempo,
    kubernetes_storage_class_v1.ebs_gp3,
  ]
}

resource "helm_release" "opentelemetry_collector" {
  name       = "otel-collector"
  repository = "https://open-telemetry.github.io/opentelemetry-helm-charts"
  chart      = "opentelemetry-collector"
  version    = local.helm_chart_versions.opentelemetry_collector

  namespace        = local.observability_namespace
  create_namespace = false

  values = [file("${path.module}/helm_values/otel-values.yaml")]

  wait    = true
  timeout = 1200

  depends_on = [
    module.eks,
    kubernetes_namespace.monitoring,
    helm_release.tempo,
    helm_release.prometheus,
  ]
}
