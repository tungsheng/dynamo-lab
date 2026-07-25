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

  # 2. Remove the fleet (both profiles) so any LoadBalancer Services release their ELBs and no
  #    worker pods remain that would keep Karpenter nodes busy.
  "$SCRIPTS_DIR/fleet.sh" down agg    >/dev/null 2>&1 || true
  "$SCRIPTS_DIR/fleet.sh" down disagg >/dev/null 2>&1 || true

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

  ok "in-cluster cleanup attempted"
else
  warn "cluster ${CLUSTER_NAME} not reachable — skipping in-cluster cleanup, proceeding to terraform destroy"
fi

# 7. The authoritative teardown: destroy terraform/main.
"$SCRIPTS_DIR/infra.sh" down

step "dynamo-lab is DOWN"
ok "idle cost is \$0 (state bucket from bootstrap is intentionally retained)"
