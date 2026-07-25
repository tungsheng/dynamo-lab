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

# 3 to match the system node group size — the etcd HA quorum (3 members, hard
# anti-affinity) needs 3 distinct nodes, so resume must restore all three.
SYS_NG_DESIRED="${SYS_NG_DESIRED:-3}"
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

# 2. Wait for at least one node to register AND go Ready. `kubectl wait --all` no-ops (returns
#    success immediately) when ZERO nodes exist yet — exactly the state right after a
#    scale-from-0 — so poll for a Ready node instead. The ' Ready ' pattern (surrounding
#    spaces) matches the STATUS column without also matching 'NotReady'.
log "waiting for a system node to register and go Ready (up to 5m)..."
_deadline=$((SECONDS + 300))
until kubectl get nodes --no-headers 2>/dev/null | grep -q ' Ready '; do
  if (( SECONDS >= _deadline )); then
    warn "no node reached Ready within 5m — check the EKS console (continuing anyway)"
    break
  fi
  sleep 5
done
if kubectl get nodes --no-headers 2>/dev/null | grep -q ' Ready '; then
  ok "a system node is Ready"
fi

# 3. Scale the Karpenter controller back up so it can provision worker capacity.
log "scaling Karpenter controller to ${KARPENTER_REPLICAS}"
kubectl -n "$NS_KARPENTER" scale deployment "$REL_KARPENTER" --replicas="$KARPENTER_REPLICAS" >/dev/null 2>&1 \
  || warn "could not scale karpenter deployment back up (is it installed?)"

step "Resumed"
ok "cluster is back; Karpenter will provision worker nodes on demand"
