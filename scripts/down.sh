#!/usr/bin/env bash
# scripts/down.sh
# Full teardown -> idle cost $0. `down` means terraform destroy of terraform/main.
#
# Before destroying, we best-effort remove in-cluster workloads that create
# out-of-band AWS resources (LoadBalancers, Karpenter EC2 instances, EBS volumes)
# so terraform destroy does not leave orphans or stall on the VPC.
#
# chmod +x scripts/down.sh
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

step "dynamo-lab DOWN — full teardown"

# Pre-destroy cleanup only makes sense if the cluster is still reachable.
if aws eks describe-cluster --name "$CLUSTER_NAME" --region "$REGION" >/dev/null 2>&1; then
  if aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$REGION" >/dev/null 2>&1; then
    log "cleaning in-cluster workloads before destroy (best-effort)"

    # Terminate Karpenter-provisioned nodes so no EC2 instances outlive the VPC.
    kubectl delete nodeclaims --all --ignore-not-found >/dev/null 2>&1 || true

    # Remove the fleet (both profiles) and platform helm releases so any
    # LoadBalancer Services release their ELBs.
    "$SCRIPTS_DIR/fleet.sh" down agg    >/dev/null 2>&1 || true
    "$SCRIPTS_DIR/fleet.sh" down disagg >/dev/null 2>&1 || true
    "$SCRIPTS_DIR/platform.sh" down     >/dev/null 2>&1 || true
    ok "in-cluster cleanup attempted"
  else
    warn "could not reach the cluster — skipping in-cluster cleanup"
  fi
else
  warn "cluster ${CLUSTER_NAME} not found — proceeding straight to terraform destroy"
fi

# The authoritative teardown: destroy terraform/main.
"$SCRIPTS_DIR/infra.sh" down

step "dynamo-lab is DOWN"
ok "idle cost is \$0 (state bucket from bootstrap is intentionally retained)"
