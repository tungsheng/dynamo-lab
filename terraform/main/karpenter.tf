# terraform/main/karpenter.tf
#
# Karpenter node-autoscaling (ADR 0008). Two halves:
#   1. The EKS module's Karpenter submodule provisions the AWS-side IAM/plumbing:
#      - the node IAM role + instance profile Karpenter-launched nodes assume
#      - the controller's permissions, granted via EKS Pod Identity (no OIDC annotation)
#      - the SQS interruption queue (spot rebalance / termination notices)
#   2. A helm_release installs the Karpenter CONTROLLER into the `karpenter` namespace.
#
# The NodePool + EC2NodeClass (what to actually launch) live in platform/karpenter/ and are
# applied by scripts, NOT Terraform — so node shapes can be tweaked without a terraform run.

module "karpenter" {
  source  = "terraform-aws-modules/eks/aws//modules/karpenter"
  version = "~> 21.24" # must match the eks module major/minor line

  cluster_name = module.eks.cluster_name

  namespace = "karpenter"

  # Auth via EKS Pod Identity. v21 removed `enable_pod_identity` and `enable_v1_permissions`:
  # Pod Identity and the Karpenter v1 controller policy are now the only (default) behavior.
  # We still create the association explicitly (needs the eks-pod-identity-agent addon).
  create_pod_identity_association = true

  # Let Karpenter nodes be SSM-managed (handy for a lab) and pull ECR images.
  node_iam_role_additional_policies = {
    AmazonSSMManagedInstanceCore = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
  }

  tags = local.common_tags
}

resource "helm_release" "karpenter" {
  namespace        = "karpenter"
  create_namespace = true

  name       = "karpenter"
  repository = "oci://public.ecr.aws/karpenter"
  chart      = "karpenter"
  version    = "1.0.8" # VERIFY: latest Karpenter 1.x chart compatible with cluster_version

  # Don't block on full rollout; the NodePool/EC2NodeClass are applied later by scripts.
  wait = false

  values = [
    yamlencode({
      # Pod Identity association is bound to serviceAccount "karpenter" in ns "karpenter"
      # (the chart's default SA name), so we do NOT set an IRSA role annotation.
      serviceAccount = {
        name = "karpenter"
      }

      settings = {
        clusterName       = module.eks.cluster_name
        clusterEndpoint   = module.eks.cluster_endpoint
        interruptionQueue = module.karpenter.queue_name
      }

      # Run the controller on the system managed node group (Karpenter can't schedule
      # its own controller onto nodes it hasn't created yet).
      nodeSelector = {
        "dynamo-lab/node-pool" = "system"
      }

      controller = {
        resources = {
          requests = { cpu = "500m", memory = "512Mi" }
          limits   = { cpu = "1", memory = "1Gi" }
        }
      }
    })
  ]

  depends_on = [
    module.eks,
    module.karpenter,
  ]
}
