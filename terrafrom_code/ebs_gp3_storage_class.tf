# EBS CSI 드라이버(ebs.csi.aws.com)용 StorageClass — 인트리 gp2와 별개로 Loki 등 PVC에 사용

resource "kubernetes_storage_class_v1" "ebs_gp3" {
  metadata {
    name = "gp3"
  }

  storage_provisioner    = "ebs.csi.aws.com"
  reclaim_policy         = "Delete"
  volume_binding_mode    = "WaitForFirstConsumer"
  allow_volume_expansion = true

  parameters = {
    type   = "gp3"
    fsType = "ext4"
  }

  depends_on = [
    module.eks,
    aws_eks_addon.ebs_csi_driver,
  ]
}
