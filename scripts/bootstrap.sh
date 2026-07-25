#!/usr/bin/env bash
# scripts/bootstrap.sh
# One-time (idempotent) creation of the Terraform state S3 bucket.
#
# The bucket is managed by terraform/bootstrap, which keeps its OWN local state
# (it cannot store state in the very bucket it creates). The bucket is versioned,
# encrypted and public-access-blocked. Name convention:
#     dynamo-lab-tfstate-<AWS_ACCOUNT_ID>
#
# Safe to run repeatedly: terraform apply is a no-op once the bucket exists.
#
# chmod +x scripts/bootstrap.sh
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

require_cmd aws terraform

BUCKET="$(state_bucket)"
ACCOUNT="$(aws_account_id)"

step "Bootstrap: Terraform state bucket"
log "account   : ${ACCOUNT}"
log "region    : ${REGION}"
log "bucket    : ${BUCKET}"

if aws s3api head-bucket --bucket "$BUCKET" >/dev/null 2>&1; then
  ok "state bucket already exists — ensuring terraform/bootstrap is reconciled"
else
  log "state bucket does not exist yet — will be created by terraform/bootstrap"
fi

# terraform/bootstrap is expected to accept: region, bucket_name.
# (These are passed as -var; terraform emits a harmless warning for any it does
#  not declare, so this stays robust if the module computes the name itself.)
terraform -chdir="$TF_BOOTSTRAP_DIR" init -input=false >/dev/null
terraform -chdir="$TF_BOOTSTRAP_DIR" apply -input=false -auto-approve \
  -var "region=${REGION}" \
  -var "bucket_name=${BUCKET}"

ok "state bucket ready: ${BUCKET}"
