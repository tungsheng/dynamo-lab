#!/usr/bin/env bash
# scripts/pause.sh
# Cheap overnight suspend: scale all nodes to zero but KEEP the cluster.
#   1. drain Karpenter capacity (delete NodeClaims while the controller runs)
#   2. scale the Karpenter controller to 0 (stop provisioning)
#   3. scale the system managed node group to 0
# The EKS control plane keeps billing (~pennies/hr); use `make down` for $0.
# Reverse with `make resume`.
#
# chmod +x scripts/pause.sh
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

require_cmd aws kubectl
ensure_kubeconfig

step "Pause: scaling all nodes to zero (cluster preserved)"

# 1. Remove Karpenter-provisioned nodes cleanly (controller still up to process
#    nodeclaim finalizers → instances drain and terminate).
log "deleting Karpenter NodeClaims (drains elastic worker nodes)"
kubectl delete nodeclaims --all --ignore-not-found >/dev/null 2>&1 || true

# 2. Stop Karpenter from provisioning new capacity.
log "scaling Karpenter controller to 0"
kubectl -n "$NS_KARPENTER" scale deployment "$REL_KARPENTER" --replicas=0 >/dev/null 2>&1 \
  || warn "could not scale karpenter deployment (already down?)"

# 3. Scale the system managed node group to zero.
NG="$(aws eks list-nodegroups --cluster-name "$CLUSTER_NAME" --region "$REGION" \
  --query 'nodegroups[0]' --output text 2>/dev/null || true)"
if [[ -n "$NG" && "$NG" != "None" ]]; then
  log "scaling system node group '${NG}' to desired=0"
  aws eks update-nodegroup-config --cluster-name "$CLUSTER_NAME" --region "$REGION" \
    --nodegroup-name "$NG" \
    --scaling-config minSize=0,maxSize=2,desiredSize=0 >/dev/null
  ok "system node group scaling to 0 (takes a few minutes to drain)"
else
  warn "no managed node group found to scale down"
fi

step "Paused"
ok "resume with: make resume"
