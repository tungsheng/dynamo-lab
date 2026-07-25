# terraform/bootstrap/versions.tf
#
# Bootstrap keeps its OWN local state (terraform.tfstate committed-ignored on disk).
# It exists only to create the S3 bucket that terraform/main uses as its remote backend,
# solving the chicken-and-egg problem: main's backend bucket must exist before `init`.

terraform {
  required_version = ">= 1.9.0" # native S3 state locking (use_lockfile) needs >= 1.9

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.60" # VERIFY: latest hashicorp/aws 5.x at build time
    }
  }
}
