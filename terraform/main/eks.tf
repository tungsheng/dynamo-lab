# terraform/main/eks.tf
#
# EKS cluster + a small SYSTEM managed node group (2x m7i.large) that hosts controllers and
# the observability stack. Elastic worker capacity is provisioned by Karpenter (karpenter.tf
# + platform/karpenter/ manifests), NOT by this node group — see ADR 0008.
#
# CPU-only lab: no GPU instance types, no NVIDIA device plugin (workers are the mocker).

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.31" # VERIFY: latest terraform-aws-modules/eks/aws 20.x

  cluster_name    = var.cluster_name
  cluster_version = var.cluster_version

  cluster_endpoint_public_access       = var.cluster_endpoint_public_access
  cluster_endpoint_public_access_cidrs = var.cluster_endpoint_public_access_cidrs

  # The identity running `terraform apply` gets cluster-admin, so kubectl works immediately.
  enable_cluster_creator_admin_permissions = true
  authentication_mode                      = "API_AND_CONFIG_MAP"

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  # Managed addons. vpc-cni is installed before compute so pods get IPs on first boot;
  # ebs-csi uses a dedicated IRSA role (iam.tf). eks-pod-identity-agent backs Karpenter's
  # Pod Identity auth (karpenter.tf).
  cluster_addons = {
    coredns = {
      most_recent = true
    }
    kube-proxy = {
      most_recent = true
    }
    vpc-cni = {
      most_recent    = true
      before_compute = true
    }
    eks-pod-identity-agent = {
      most_recent = true
    }
    aws-ebs-csi-driver = {
      most_recent              = true
      service_account_role_arn = module.ebs_csi_irsa.iam_role_arn
    }
  }

  eks_managed_node_groups = {
    system = {
      # Controllers + observability. Kept small and fixed; the elastic pool is Karpenter's.
      instance_types = [var.system_node_instance_type]
      capacity_type  = "ON_DEMAND"

      ami_type = "AL2023_x86_64_STANDARD" # VERIFY: AL2023 standard x86_64 EKS-optimized AMI

      min_size     = var.system_node_min_size
      max_size     = var.system_node_max_size
      desired_size = var.system_node_desired_size

      labels = {
        "app.kubernetes.io/part-of" = "dynamo-lab"
        "dynamo-lab/node-pool"      = "system"
      }

      tags = {
        "dynamo-lab/node-pool" = "system"
      }
    }
  }

  # Tag the cluster security group so Karpenter-launched nodes can discover it.
  node_security_group_tags = {
    "karpenter.sh/discovery" = var.cluster_name
  }

  tags = local.common_tags
}
