# terraform/main/providers.tf
#
# The kubernetes + helm providers authenticate to the cluster with a short-lived token from
# `aws eks get-token` (exec plugin). This avoids baking a token into state and refreshes it
# on every apply. NOTE: because these providers depend on module.eks outputs, a first apply
# creates the cluster and the in-cluster resources (addons via the module, Karpenter helm
# release) in the same graph; the exec plugin resolves the token lazily at apply time.

locals {
  common_tags = merge(
    {
      "app.kubernetes.io/part-of" = "dynamo-lab"
      "project"                   = var.project
      "managed-by"                = "terraform"
      "terraform-root"            = "main"
    },
    var.tags,
  )
}

provider "aws" {
  region = var.region

  default_tags {
    tags = local.common_tags
  }
}

provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name, "--region", var.region]
  }
}

provider "helm" {
  kubernetes {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)

    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name, "--region", var.region]
    }
  }
}
