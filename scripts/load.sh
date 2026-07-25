#!/usr/bin/env bash
# scripts/load.sh  start|stop  [baseline|ramp|spike|sustained|soak]
# Run / stop a k6 load profile against the Dynamo frontend. Default: spike.
#
# load/k6-job.yaml is self-contained (Job + embedded 'k6-script' ConfigMap), so
# no separate script ConfigMap is synced here. The traffic shape is injected via
# the ${PROFILE} placeholder and the target via ${FRONTEND_URL} (derived from the
# TOPOLOGY selector: agg|disagg), both rendered by envsubst before apply.
# TOPOLOGY (fleet shape) is INDEPENDENT of PROFILE (traffic shape).
#
# chmod +x scripts/load.sh
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

require_cmd kubectl

ACTION="${1:-start}"
PROFILE="${2:-${PROFILE:-spike}}"

case "$PROFILE" in
  baseline|ramp|spike|sustained|soak) ;;
  *) die "unknown load profile '${PROFILE}' (expected baseline|ramp|spike|sustained|soak)" ;;
esac

# TOPOLOGY (agg|disagg) selects the target fleet; FRONTEND_URL is derived from it
# in common.sh and is INDEPENDENT of the traffic PROFILE above. Override TOPOLOGY
# or FRONTEND_URL via the environment.
case "$TOPOLOGY" in
  agg|disagg) ;;
  *) die "unknown fleet topology '${TOPOLOGY}' (expected agg|disagg)" ;;
esac

JOB_MANIFEST="${LOAD_DIR}/k6-job.yaml"
export PROFILE TOPOLOGY FRONTEND_URL CLUSTER_NAME REGION

case "$ACTION" in
  start)
    ensure_kubeconfig
    ensure_namespace "$NS_LOAD"
    step "Load start (profile=${PROFILE}, topology=${TOPOLOGY} -> ${FRONTEND_URL})"
    [[ -f "$JOB_MANIFEST" ]] || die "k6 job manifest not found: ${JOB_MANIFEST}"
    # Jobs are largely immutable — clear any previous run first.
    render < "$JOB_MANIFEST" | kubectl delete --ignore-not-found -f - >/dev/null 2>&1 || true
    apply_manifests "$JOB_MANIFEST"
    ok "k6 job started with profile '${PROFILE}'"
    log "follow logs:  kubectl -n ${NS_LOAD} logs -f job/k6-load"
    ;;
  stop)
    ensure_kubeconfig
    step "Load stop"
    delete_manifests "$JOB_MANIFEST"
    ok "k6 job removed"
    ;;
  *)
    die "usage: load.sh start|stop [baseline|ramp|spike|sustained|soak]"
    ;;
esac
