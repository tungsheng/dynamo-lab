# terraform/main/outputs.tf

output "cluster_name" {
  description = "EKS cluster name."
  value       = module.eks.cluster_name
}

output "cluster_endpoint" {
  description = "EKS control-plane API endpoint."
  value       = module.eks.cluster_endpoint
}

output "cluster_certificate_authority_data" {
  description = "Base64 CA cert for the cluster (used by kube/helm providers)."
  value       = module.eks.cluster_certificate_authority_data
  sensitive   = true
}

output "cluster_version" {
  description = "Kubernetes version of the cluster."
  value       = module.eks.cluster_version
}

output "region" {
  description = "AWS region the cluster runs in."
  value       = var.region
}

output "oidc_provider_arn" {
  description = "IRSA OIDC provider ARN (for any future IRSA roles)."
  value       = module.eks.oidc_provider_arn
}

output "vpc_id" {
  description = "VPC ID."
  value       = module.vpc.vpc_id
}

output "private_subnet_ids" {
  description = "Private subnet IDs (where nodes run; tagged for Karpenter discovery)."
  value       = module.vpc.private_subnets
}

output "karpenter_node_iam_role_name" {
  description = "IAM role name Karpenter-launched nodes assume — referenced by the EC2NodeClass in platform/karpenter/."
  value       = module.karpenter.node_iam_role_name
}

output "karpenter_queue_name" {
  description = "SQS interruption queue Karpenter watches."
  value       = module.karpenter.queue_name
}

# The exact command `make kubeconfig` runs so kubectl/helm can reach the cluster.
output "kubeconfig_command" {
  description = "Run this to point kubectl at the cluster."
  value       = "aws eks update-kubeconfig --name ${module.eks.cluster_name} --region ${var.region}"
}
