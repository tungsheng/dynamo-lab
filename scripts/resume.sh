#!/usr/bin/env bash
# scripts/resume.sh
# Reverse of pause.sh: bring the cluster's nodes back.
#   1. scale the system managed node group back up (default 2)
#   2. wait for a node to register
#   3. scale the Karpenter controller back up
# Karpenter then re-provisions elastic worker capacity on demand.
#
# chmod +x scripts/resume.sh
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

require_cmd aws kubectl
ensure_kubeconfig

SYS_NG_DESIRED="${SYS_NG_DESIRED:-2}"
KARPENTER_REPLICAS="${KARPENTER_REPLICAS:-1}"

step "Resume: bringing nodes back"

# 1. Scale the system managed node group back up.
NG="$(aws eks list-nodegroups --cluster-name "$CLUSTER_NAME" --region "$REGION" \
  --query 'nodegroups[0]' --output text 2>/dev/null || true)"
if [[ -n "$NG" && "$NG" != "None" ]]; then
  log "scaling system node group '${NG}' to desired=${SYS_NG_DESIRED}"
  aws eks update-nodegroup-config --cluster-name "$CLUSTER_NAME" --region "$REGION" \
    --nodegroup-name "$NG" \
    --scaling-config "minSize=${SYS_NG_DESIRED},maxSize=${SYS_NG_DESIRED},desiredSize=${SYS_NG_DESIRED}" >/dev/null
  ok "system node group scaling to ${SYS_NG_DESIRED}"
else
  warn "no managed node group found to scale up"
fi

# 2. Wait for at least one node to become Ready.
log "waiting for a system node to register (up to 5m)..."
if kubectl wait --for=condition=Ready node --all --timeout=300s >/dev/null 2>&1; then
  ok "nodes Ready"
else
  warn "nodes not Ready within timeout — check the EKS console"
fi

# 3. Scale the Karpenter controller back up so it can provision worker capacity.
log "scaling Karpenter controller to ${KARPENTER_REPLICAS}"
kubectl -n "$NS_KARPENTER" scale deployment "$REL_KARPENTER" --replicas="$KARPENTER_REPLICAS" >/dev/null 2>&1 \
  || warn "could not scale karpenter deployment back up (is it installed?)"

step "Resumed"
ok "cluster is back; Karpenter will provision worker nodes on demand"
