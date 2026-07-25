#!/usr/bin/env bash
# scripts/infra.sh  up|down
# Terraform lifecycle for terraform/main (VPC + EKS + Karpenter IAM/IRSA + SQS +
# system managed node group). Uses the partial S3 backend defined in the spec.
#
# chmod +x scripts/infra.sh
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

require_cmd aws terraform

ACTION="${1:-up}"
BUCKET="$(state_bucket)"

tf_init() {
  step "Terraform init (partial S3 backend)"
  log "bucket=${BUCKET} key=${TF_STATE_KEY} region=${REGION}"
  # -reconfigure keeps init idempotent across re-runs / backend changes.
  # Only bucket/key/region are passed here (the account-portable partial config);
  # native S3 locking (use_lockfile=true) is set statically in
  # terraform/main/backend.tf since it is not environment-specific.
  terraform -chdir="$TF_MAIN_DIR" init -input=false -reconfigure \
    -backend-config="bucket=${BUCKET}" \
    -backend-config="key=${TF_STATE_KEY}" \
    -backend-config="region=${REGION}"
}

case "$ACTION" in
  up)
    tf_init
    step "Terraform apply (terraform/main)"
    terraform -chdir="$TF_MAIN_DIR" apply -input=false -auto-approve \
      -var "region=${REGION}"
    ok "infrastructure applied"
    ;;
  down)
    tf_init
    step "Terraform destroy (terraform/main)"
    terraform -chdir="$TF_MAIN_DIR" destroy -input=false -auto-approve \
      -var "region=${REGION}"
    ok "infrastructure destroyed — main resources billing \$0"
    ;;
  *)
    die "usage: infra.sh up|down"
    ;;
esac
