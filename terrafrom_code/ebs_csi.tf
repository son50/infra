# EBS CSI: IAM 역할(IRSA) 없이 EKS 관리형 애드온만 쓰면 Pod가 권한 없이 CREATING에서 20분 타임아웃 나는 경우가 많음.
# 클러스터·OIDC 생성 후, 전용 역할을 붙여 애드온을 설치한다.

data "aws_eks_addon_version" "ebs_csi" {
  addon_name         = "aws-ebs-csi-driver"
  kubernetes_version = var.KubernetesVersion
  most_recent        = true
}

module "ebs_csi_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.48"

  role_name = "${local.ClusterBaseName}-ebs-csi"

  attach_ebs_csi_policy = true

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:ebs-csi-controller-sa"]
    }
  }

  tags = {
    Project     = var.project
    Environment = var.env
    Terraform   = "true"
  }
}

resource "aws_eks_addon" "ebs_csi_driver" {
  cluster_name                 = module.eks.cluster_name
  addon_name                   = "aws-ebs-csi-driver"
  addon_version                = data.aws_eks_addon_version.ebs_csi.version
  service_account_role_arn     = module.ebs_csi_irsa.iam_role_arn
  resolve_conflicts_on_create  = "OVERWRITE"
  resolve_conflicts_on_update  = "OVERWRITE"

  timeouts {
    create = "60m"
    update = "60m"
    delete = "60m"
  }

  depends_on = [
    module.eks,
    module.ebs_csi_irsa,
  ]
}
