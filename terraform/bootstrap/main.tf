# terraform/bootstrap/main.tf
#
# Creates the S3 bucket that terraform/main uses for remote state.
# Bucket is versioned (recoverable state), encrypted (SSE), and fully public-access-blocked.
# Naming convention (must match terraform/main/backend.tf -backend-config):
#     bucket = dynamo-lab-tfstate-<AWS_ACCOUNT_ID>
#
# This root uses LOCAL state on purpose (see ADR 0006): it is the one thing that must exist
# before any remote backend can. Keep terraform/bootstrap/terraform.tfstate safe.

data "aws_caller_identity" "current" {}

locals {
  account_id  = data.aws_caller_identity.current.account_id
  bucket_name = "${var.project}-tfstate-${local.account_id}"
}

resource "aws_s3_bucket" "tfstate" {
  bucket = local.bucket_name

  # A lab bucket that must never be silently destroyed while state lives in it.
  # Emptying + deleting it is a deliberate manual op (see scripts / README).
  lifecycle {
    prevent_destroy = true
  }

  tags = {
    Name = local.bucket_name
  }
}

# Versioning: lets us recover a clobbered or corrupted state file (ADR 0006 rationale).
resource "aws_s3_bucket_versioning" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id
  versioning_configuration {
    status = "Enabled"
  }
}

# Server-side encryption at rest (SSE-S3 / AES256; no KMS key to manage for a lab).
resource "aws_s3_bucket_server_side_encryption_configuration" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
    bucket_key_enabled = true
  }
}

# Block ALL public access — state files contain sensitive infrastructure detail.
resource "aws_s3_bucket_public_access_block" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Enforce bucket-owner ownership (disable ACLs) — modern S3 best practice.
resource "aws_s3_bucket_ownership_controls" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}
