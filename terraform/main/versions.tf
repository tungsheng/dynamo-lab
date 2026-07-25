# terraform/main/versions.tf
#
# Provider requirements for the main root. The S3 backend block lives in backend.tf
# (partial config — bucket/key/region supplied at `init` via -backend-config).

terraform {
  required_version = ">= 1.10.0" # native S3 state locking (use_lockfile, see backend.tf) needs >= 1.10

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.60" # VERIFY: latest hashicorp/aws 5.x at build time
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.16" # VERIFY: pinned to 2.x so the nested `kubernetes {}` provider block works; helm 3.x changed this
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.32" # VERIFY: latest hashicorp/kubernetes 2.x
    }
  }
}
