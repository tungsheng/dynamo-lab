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
  # Public /24s sit at netnum 200+ so they never overlap the private /20 space. With
  # az_count=4 the private /20s occupy /20 netnums 0-3 (10.0.0.0-10.0.63.255); a /24 at
  # netnum 48 (the old offset) would fall inside the 4th private /20. Offset 200 keeps the
  # public block disjoint from any private /20.
  public_subnets = [for k, v in local.azs : cidrsubnet(var.vpc_cidr, 8, k + 200)]

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
