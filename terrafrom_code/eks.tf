########################
# Provider Definitions #
########################

# 변수 조립
locals {
  ClusterBaseName = "${var.project}-${var.env}-eks-${var.num}"
}


# AWS 공급자: 지정된 리전에서 AWS 리소스를 설정
provider "aws" {
  region = var.TargetRegion
}


########################
# Security Group Setup #
########################

# 보안 그룹: EKS 워커 노드용 보안 그룹 생성
resource "aws_security_group" "node_group_sg" {
  name        = "${local.ClusterBaseName}-node-group-sg"
  description = "Security group for EKS Node Group"
  vpc_id      = module.vpc.vpc_id

  tags = {
    Name = "${local.ClusterBaseName}-node-group-sg"
  }
}

# 보안 그룹 규칙: EKS 워커 노드로 접속 허용
resource "aws_security_group_rule" "node_inbound" {
  type        = "ingress"
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  cidr_blocks = [
    var.ssh_access_cidr,
    var.VpcBlock
  ]
  security_group_id = aws_security_group.node_group_sg.id
}

# 3. 아웃바운드 규칙 
resource "aws_security_group_rule" "node_outbound" {
  type              = "egress"
  from_port         = 0
  to_port           = 0
  protocol          = "-1" # 외부로 나가는 모든 트래픽 허용
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.node_group_sg.id
}


########################
# EKS
########################

# https://registry.terraform.io/modules/terraform-aws-modules/eks/aws/latest
module "eks" {
  
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 21.0"

  name               = local.ClusterBaseName
  kubernetes_version = var.KubernetesVersion

  vpc_id = module.vpc.vpc_id
  subnet_ids = module.vpc.public_subnets

  enable_irsa = true

  # coredns 등 나머지 애드온용 (EBS CSI는 IRSA 붙여 root에서 별도 설치)
  addons_timeouts = {
    create = "45m"
    update = "45m"
    delete = "45m"
  }

  endpoint_public_access = true
  endpoint_private_access = true
  # endpoint_public_access_cidrs = [
  #   var.ssh_access_cidr
  # ]

  # controlplane log
  # cloudwatch로 보내는 로그 관리
  enabled_log_types = []

  # Optional: Adds the current caller identity as an administrator via cluster access entry
  enable_cluster_creator_admin_permissions = true

  # EKS Managed Node Group(s)
  eks_managed_node_groups = {
    # 1st 노드 그룹
    primary = {
      # 예전 이름(...-1nd-node-group)과 다르게 해야 인스턴스 타입 교체 시 같은 이름으로 create→409 나는 걸 피하기 쉬움
      name             = "${local.ClusterBaseName}-primary"
      use_name_prefix  = false
      # 노드 그룹명이 길면 IAM role name_prefix가 AWS 제한(38자) 초과 → 고정 이름 사용
      iam_role_use_name_prefix = false
      iam_role_name            = "${local.ClusterBaseName}-worker"
      instance_types   = ["${var.WorkerNodeInstanceType}"]
      desired_size     = var.WorkerNodeCount
      max_size         = var.WorkerNodeCount + 2
      min_size         = var.WorkerNodeCount - 1
      disk_size        = var.WorkerNodeVolumesize
      subnets          = module.vpc.public_subnets
      key_name         = "${var.KeyName}"
      vpc_security_group_ids = [aws_security_group.node_group_sg.id]
      
      # node label
      labels = {
        tier = "primary"
      }

      # AL2023 전용 userdata 주입
      cloudinit_pre_nodeadm = [
        {
          content_type = "text/x-shellscript"
          content      = <<-EOT
            #!/bin/bash
            echo "Starting custom initialization..."
            dnf update -y
            dnf install -y tree bind-utils tcpdump nvme-cli links sysstat ipset htop
            echo "Custom initialization completed."
          EOT
        }
      ]
    }

    # 2nd 노드 그룹 (추가)
    # secondary = {
    #   name            = "${var.ClusterBaseName}-2nd-node-group"
    #   use_name_prefix = false
    
    #   instance_types  = ["c5.large"] 
    #   desired_size    = 1
    #   max_size        = 1
    #   min_size        = 1
      
    #   subnets          = module.vpc.public_subnets  # module.vpc.private_subnets
    #   key_name         = "${var.KeyName}"
    #   vpc_security_group_ids = [aws_security_group.node_group_sg.id]
      
    #   # node label
    #   labels = {
    #     tier = "secondary"
    #   }

    #   # AL2023 전용 userdata 주입
    #   cloudinit_pre_nodeadm = [
    #     {
    #       content_type = "text/x-shellscript"
    #       content      = <<-EOT
    #         #!/bin/bash
    #         echo "Starting custom initialization..."
    #         dnf update -y
    #         dnf install -y tree bind-utils tcpdump nvme-cli links sysstat ipset htop
    #         echo "Custom initialization completed."
    #       EOT
    #     }
    #   ]
    # }

  }

  # add-on
  addons = {
    coredns = {
      most_recent = true
    }
    kube-proxy = {
      most_recent = true
    }
    vpc-cni = {
      most_recent = true
      before_compute = true
      configuration_values = jsonencode({
        env = {
          #WARM_ENI_TARGET = "1" # 현재 ENI 외에 여유 ENI 1개를 항상 확보
          #WARM_IP_TARGET  = "5" # 현재 사용 중인 IP 외에 여유 IP 5개를 항상 유지, 설정 시 WARM_ENI_TARGET 무시됨
          #MINIMUM_IP_TARGET   = "10" # 노드 시작 시 최소 확보해야 할 IP 총량 10개
          ENABLE_PREFIX_DELEGATION = "true" 
          WARM_PREFIX_TARGET = "1" # PREFIX_DELEGATION 사용 시, 1개의 여유 대역(/28) 유지
        }
      })
    }
    # aws-ebs-csi-driver 는 ebs_csi.tf 에서 IRSA(service_account_role_arn)와 함께 설치
  }

  tags = {
    Project     = var.project
    Environment = var.env
    Terraform   = "true"
  }

}
