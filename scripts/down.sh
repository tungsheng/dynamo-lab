#!/usr/bin/env bash
# scripts/down.sh
# Full teardown -> idle cost $0. `down` means terraform destroy of terraform/main.
#
# Before destroying, we best-effort remove in-cluster workloads that create out-of-band AWS
# resources (LoadBalancers, Karpenter EC2 instances, EBS volumes) so terraform destroy does
# not leave orphans or stall on the VPC. ORDER MATTERS: remove workloads BEFORE deleting
# NodeClaims, and scale the Karpenter controller to 0 first so it can't re-provision nodes
# mid-teardown. PVCs are deleted LAST while ebs-csi is still running, so their backing EBS
# volumes are released instead of orphaned (which would break "$0 idle").
#
# chmod +x scripts/down.sh
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

# EBS volumes backing the fleet/platform PVCs carry the cluster ownership tag. We use it to
# (a) wait for ebs-csi to release them before the cluster is destroyed, and (b) sweep any that
# still leak after destroy. Both guard "$0 idle": a detached-but-undeleted volume in `available`
# state keeps billing.
_cluster_volume_ids() {
  aws ec2 describe-volumes --region "$REGION" \
    --filters "Name=tag:kubernetes.io/cluster/${CLUSTER_NAME},Values=owned" \
    --query 'Volumes[].VolumeId' --output text 2>/dev/null
}

# Bounded wait for the CSI driver to delete cluster EBS volumes, so `terraform destroy` does not
# race the driver and orphan them. Best-effort: on timeout the post-destroy sweep catches any.
_wait_ebs_released() {
  local deadline=$((SECONDS + 240)) vols
  log "waiting for ebs-csi to release cluster EBS volumes (up to 4m)..."
  while :; do
    vols="$(_cluster_volume_ids)"
    [[ -z "$vols" ]] && { ok "cluster EBS volumes released"; return 0; }
    ((SECONDS >= deadline)) && { warn "timed out waiting for EBS release — post-destroy sweep will handle stragglers"; return 0; }
    sleep 10
  done
}

# Safety net AFTER destroy: the CSI driver is gone, so a leftover cluster-tagged volume can only
# be removed directly. A stray `available` volume is a billing tail that defeats "$0 idle".
_sweep_orphan_ebs() {
  local vols v
  local -a orphans
  vols="$(_cluster_volume_ids)"
  if [[ -z "$vols" ]]; then
    ok "no orphaned EBS volumes — idle cost is truly \$0"
    return 0
  fi
  read -ra orphans <<<"$vols"
  warn "orphaned EBS volume(s) survived destroy; deleting: ${vols}"
  for v in "${orphans[@]}"; do
    aws ec2 delete-volume --volume-id "$v" --region "$REGION" >/dev/null 2>&1 \
      && ok "deleted ${v}" || warn "could not delete ${v} — remove it manually"
  done
}

step "dynamo-lab DOWN — full teardown"

# 1. Confirmation gate. This wraps an irreversible `terraform destroy -auto-approve`, so an
#    interactive run must type the cluster name to confirm. CI / unattended runs bypass with
#    FORCE=1 or YES=1. (Only down.sh gates; infra-down stays unattended.)
if [[ -t 0 && -z "${FORCE:-}" && -z "${YES:-}" ]]; then
  read -rp "Destroy cluster '${CLUSTER_NAME}' in ${REGION}? Type the cluster name to confirm: " _reply
  [[ "$_reply" == "$CLUSTER_NAME" ]] || die "confirmation did not match '${CLUSTER_NAME}' — aborting teardown"
fi

# Pre-destroy cleanup only makes sense if the cluster is still reachable. Every in-cluster
# step below is tolerant of an already-gone cluster (|| true / --ignore-not-found).
if aws eks describe-cluster --name "$CLUSTER_NAME" --region "$REGION" >/dev/null 2>&1 \
   && aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$REGION" >/dev/null 2>&1; then
  log "cleaning in-cluster workloads before destroy (best-effort)"

  # 2. Remove ALL fleets — every DynamoGraphDeployment, ANY profile (agg / disagg / grove-scale /
  #    future) — so no worker pods keep the Karpenter nodes busy. A leftover fleet blocks the
  #    NodePool delete in step 3: the worker node cannot drain, and the WHOLE teardown hangs.
  #    Delete the DGDs while the operator (and Grove, for Track G) is still running so their
  #    finalizers clear. Enumerating only agg/disagg missed the Track G `grove-scale` fleet and
  #    hung the teardown for 33 min (live-diagnosed 2026-07-31). `--timeout` bounds a stuck
  #    finalizer so a slow delete can't wedge the teardown either.
  kubectl delete dynamographdeployment --all -n "$NS_DYNAMO" \
    --ignore-not-found --timeout=120s >/dev/null 2>&1 || true

  # 3. Remove the platform helm releases (etcd, NATS, operator, observability, chaos-mesh).
  "$SCRIPTS_DIR/platform.sh" down >/dev/null 2>&1 || true

  # 4. Scale the Karpenter controller to 0 so it cannot re-provision nodes while we delete
  #    NodeClaims. (kubectl scale has no --ignore-not-found flag; `|| true` covers the
  #    deployment/cluster-already-gone case.)
  kubectl -n "$NS_KARPENTER" scale deploy "$REL_KARPENTER" --replicas=0 >/dev/null 2>&1 || true

  # 5. Delete Karpenter NodeClaims so no EC2 instances outlive the VPC (controller is at 0 now,
  #    so it won't recreate them).
  kubectl delete nodeclaims --all --ignore-not-found >/dev/null 2>&1 || true

  # 6. Delete PVCs while ebs-csi is still running, so their backing EBS volumes are released
  #    instead of orphaned after terraform destroy. Covers StatefulSet/persistence PVCs:
  #    etcd, NATS (ns dynamo) and Prometheus, Loki, Tempo (ns monitoring).
  kubectl delete pvc --all -n "$NS_DYNAMO"     --ignore-not-found >/dev/null 2>&1 || true
  kubectl delete pvc --all -n "$NS_MONITORING" --ignore-not-found >/dev/null 2>&1 || true

  # 6b. Let the CSI driver finish DELETING the backing EBS volumes before we destroy the cluster
  #     (and the driver). Without this, terraform destroy races the volume deletion and leaves
  #     orphaned `available` volumes billing forever (observed: 3 leaked on 2026-07-28).
  _wait_ebs_released

  ok "in-cluster cleanup attempted"
else
  warn "cluster ${CLUSTER_NAME} not reachable — skipping in-cluster cleanup, proceeding to terraform destroy"
fi

# 7. The authoritative teardown: destroy terraform/main.
"$SCRIPTS_DIR/infra.sh" down

# 8. Sweep any EBS volumes that outlived the destroy (see _sweep_orphan_ebs). Uses aws only, so it
#    runs even if the cluster was already gone and the in-cluster cleanup above was skipped.
require_cmd aws
_sweep_orphan_ebs

step "dynamo-lab is DOWN"
ok "idle cost is \$0 (state bucket from bootstrap is intentionally retained)"
