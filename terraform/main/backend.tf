# terraform/main/backend.tf
#
# PARTIAL S3 backend. The concrete bucket/key/region are NOT hard-coded here so this repo
# is account-portable; they are injected at init time (the scripts/Makefile do this):
#
#   terraform -chdir=terraform/main init \
#     -backend-config=bucket=dynamo-lab-tfstate-<AWS_ACCOUNT_ID> \
#     -backend-config=key=main/terraform.tfstate \
#     -backend-config=region=<region>
#
# use_lockfile=true → native S3 state locking (no DynamoDB table needed; see ADR 0006).
# It is NOT environment-specific, so it is set statically in the block below rather
# than passed via -backend-config. The bucket itself is created by terraform/bootstrap.

terraform {
  backend "s3" {
    # bucket/key/region are the PARTIAL config, injected at init via -backend-config:
    # key    = "main/terraform.tfstate"   # supplied via -backend-config
    # bucket = "dynamo-lab-tfstate-<acct>" # supplied via -backend-config
    # region = "us-west-2"                 # supplied via -backend-config
    use_lockfile = true   # native S3 locking — static (not environment-specific)
    encrypt      = true
  }
}
