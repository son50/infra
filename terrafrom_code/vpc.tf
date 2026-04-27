########################
# VPC
########################

# VPC 모듈: 퍼블릭 및 프라이빗 서브넷을 포함하는 VPC를 생성
# https://registry.terraform.io/modules/terraform-aws-modules/vpc/aws/6.5.0
# Cluster 이름은 eks.tf locals.ClusterBaseName 과 동일 규칙: ${var.project}-${var.env}-eks-${var.num}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~>6.5"

  name = "${var.project}-${var.env}-vpc-${var.num}"
  cidr = var.VpcBlock
  azs  = var.availability_zones

  enable_dns_support   = true # DNS 서버 활성화
  enable_dns_hostnames = true # 인스턴스에 DNS 이름 부여

  public_subnets  = var.public_subnet_blocks
  private_subnets = var.private_subnet_blocks

  public_subnet_names = [
    for az in var.availability_zones : 
    format("${var.project}-${var.env}-pb-subnet-%s", az)
  ]

  private_subnet_names = [
    for az in var.availability_zones : 
    format("${var.project}-${var.env}-pri-subnet-%s",az)
  ]

  enable_nat_gateway = false # true
  single_nat_gateway = true
  one_nat_gateway_per_az = false
  
  manage_default_network_acl = false

  #퍼블릭 서브넷에 들어오는 ec2에 퍼블릭 IP 자동 할당
  map_public_ip_on_launch = true

  igw_tags = {
    "Name" = "${var.project}-${var.env}-igw-${var.num}"
  }

  nat_gateway_tags = {
    "Name" = "${var.project}-${var.env}-nat-${var.num}"
  }

  public_subnet_tags = {
    "kubernetes.io/role/elb"   = "1"
    "kubernetes.io/cluster/${var.project}-${var.env}-eks-${var.num}" = "shared"
  }

  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = "1"
    "kubernetes.io/cluster/${var.project}-${var.env}-eks-${var.num}" = "shared"
    "karpenter.sh/discovery"          = "${var.project}-${var.env}-eks-${var.num}"
  }

  tags = {
    "Environment" = "cloudneta-lab"
  }
}