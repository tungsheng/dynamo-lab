# terraform/main/iam.tf
#
# IRSA role for the EBS CSI driver addon (the only addon here that needs cloud permissions:
# it creates/attaches EBS volumes for PersistentVolumeClaims — e.g. etcd/NATS/Prometheus).
#
# Karpenter's IAM (controller role, node role, instance profile, interruption SQS) is handled
# by the EKS Karpenter submodule in karpenter.tf, not here.

module "ebs_csi_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 6.6" # VERIFY: latest terraform-aws-modules/iam/aws 5.x

  role_name             = "${var.cluster_name}-ebs-csi-irsa"
  attach_ebs_csi_policy = true

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:ebs-csi-controller-sa"]
    }
  }

  tags = local.common_tags
}
