# terraform/bootstrap/versions.tf
#
# Bootstrap keeps its OWN local state (terraform.tfstate committed-ignored on disk).
# It exists only to create the S3 bucket that terraform/main uses as its remote backend,
# solving the chicken-and-egg problem: main's backend bucket must exist before `init`.

terraform {
  required_version = ">= 1.5.0" # bootstrap keeps LOCAL state (no use_lockfile); any modern Terraform is fine

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.56" # VERIFY: latest hashicorp/aws 5.x at build time
    }
  }
}
