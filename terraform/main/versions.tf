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
      version = "~> 3.0" # 3.x: provider config uses `kubernetes = {}` (attribute), see providers.tf
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 3.2"
    }
  }
}
