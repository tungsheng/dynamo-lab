# terraform/main/vpc.tf
#
# A standard 3-AZ VPC with public + private subnets and a single NAT gateway (cost-trimmed
# for a lab). Worker/system nodes live in private subnets; the NAT gateway gives them egress
# (pulling images, reaching AWS APIs). Public subnets carry the (optional) load balancers.
#
# Subnet tags are what Karpenter and the AWS Load Balancer controller discover on:
#   - kubernetes.io/role/elb        (public,  for internet-facing LBs)
#   - kubernetes.io/role/internal-elb (private, for internal LBs)
#   - karpenter.sh/discovery = <cluster>  (private, so Karpenter can place nodes)

data "aws_availability_zones" "available" {
  state = "available"
  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

locals {
  azs = slice(data.aws_availability_zones.available.names, 0, var.az_count)
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.13" # VERIFY: latest terraform-aws-modules/vpc/aws 5.x

  name = "${var.project}-vpc"
  cidr = var.vpc_cidr

  azs             = local.azs
  private_subnets = [for k, v in local.azs : cidrsubnet(var.vpc_cidr, 4, k)]
  public_subnets  = [for k, v in local.azs : cidrsubnet(var.vpc_cidr, 8, k + 48)]

  enable_nat_gateway   = true
  single_nat_gateway   = true # one NAT for the whole lab — cheaper, adequate for non-prod
  enable_dns_hostnames = true
  enable_dns_support   = true

  public_subnet_tags = {
    "kubernetes.io/role/elb" = "1"
  }

  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = "1"
    # Karpenter subnet discovery (matched by the EC2NodeClass in platform/karpenter/).
    "karpenter.sh/discovery" = var.cluster_name
  }

  tags = local.common_tags
}
