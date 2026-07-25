#!/usr/bin/env bash
# scripts/fleet.sh  up|down  [agg|disagg]
# Deploy / remove just the Dynamo fleet (a single DynamoGraphDeployment) on a
# live cluster — the fast inner loop. Default profile: agg.
#
# chmod +x scripts/fleet.sh
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

require_cmd kubectl

ACTION="${1:-up}"
PROFILE="${2:-${PROFILE:-agg}}"

case "$PROFILE" in
  agg|disagg) ;;
  *) die "unknown fleet profile '${PROFILE}' (expected agg|disagg)" ;;
esac

MANIFEST="${FLEET_DIR}/${PROFILE}.yaml"
export PROFILE DYNAMO_VERSION CLUSTER_NAME REGION

fleet_up() {
  ensure_kubeconfig
  [[ -f "$MANIFEST" ]] || die "fleet manifest not found: ${MANIFEST}"
  ensure_namespace "$NS_DYNAMO"

  step "Fleet up (profile=${PROFILE})"
  apply_manifests "$MANIFEST"
  ok "applied ${MANIFEST}"

  # Wait for the operator to reconcile the DGD. Condition types on the CRD are
  # version-sensitive, so we try the DGD condition first and fall back to
  # waiting on the fleet pods.
  # VERIFY: DynamoGraphDeployment ready condition type (Ready vs Available).
  log "waiting for the fleet to become ready..."
  if kubectl -n "$NS_DYNAMO" wait --for=condition=Ready \
       dynamographdeployment --all --timeout=600s >/dev/null 2>&1; then
    ok "DynamoGraphDeployment reports Ready"
  else
    warn "DGD Ready condition not observed — falling back to pod readiness"
    kubectl -n "$NS_DYNAMO" wait --for=condition=Ready pod \
      -l app.kubernetes.io/part-of=dynamo-lab --timeout=600s \
      || warn "some fleet pods did not reach Ready within timeout"
  fi

  step "Fleet status"
  kubectl -n "$NS_DYNAMO" get dynamographdeployment 2>/dev/null || true
  kubectl -n "$NS_DYNAMO" get pods -l app.kubernetes.io/part-of=dynamo-lab
}

fleet_down() {
  ensure_kubeconfig
  step "Fleet down (profile=${PROFILE})"
  if [[ -f "$MANIFEST" ]]; then
    delete_manifests "$MANIFEST"
    ok "deleted ${MANIFEST}"
  else
    warn "manifest ${MANIFEST} missing — deleting DynamoGraphDeployments by label instead"
    kubectl -n "$NS_DYNAMO" delete dynamographdeployment \
      -l app.kubernetes.io/part-of=dynamo-lab --ignore-not-found || true
  fi
}

case "$ACTION" in
  up)   fleet_up ;;
  down) fleet_down ;;
  *)    die "usage: fleet.sh up|down [agg|disagg]" ;;
esac
