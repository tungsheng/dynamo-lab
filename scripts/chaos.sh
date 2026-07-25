#!/usr/bin/env bash
# scripts/chaos.sh  start|stop
# Start / stop the randomized "chaos monkey": a Chaos Mesh Schedule plus the
# chaos annotation bridge that turns fault events into Grafana annotations.
#
#   start -> apply chaos/schedule-monkey.yaml + chaos/annotation-bridge/ (dir)
#   stop  -> delete both (existing pods heal; no new faults injected)
#
# chmod +x scripts/chaos.sh
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

require_cmd kubectl

ACTION="${1:-start}"

SCHEDULE_MANIFEST="${CHAOS_DIR}/schedule-monkey.yaml"
# The annotation bridge is a directory of manifests (configmap/deployment/rbac);
# apply_manifests/delete_manifests apply every *.yaml under it EXCEPT the
# secret.example.yaml placeholder (skipped as *example*). Provide the real
# chaos-annotation-bridge-grafana Secret out-of-band (see secret.example.yaml).
BRIDGE_MANIFEST="${CHAOS_DIR}/annotation-bridge"

export CLUSTER_NAME REGION

case "$ACTION" in
  start)
    ensure_kubeconfig
    step "Chaos start"
    # The annotation bridge watches Chaos Mesh events and posts Grafana
    # annotations; bring it up alongside the schedule.
    if [[ -d "$BRIDGE_MANIFEST" ]]; then
      apply_manifests "$BRIDGE_MANIFEST"
      ok "chaos annotation bridge applied"
    else
      warn "annotation bridge manifests missing: ${BRIDGE_MANIFEST}"
    fi
    [[ -f "$SCHEDULE_MANIFEST" ]] || die "schedule manifest not found: ${SCHEDULE_MANIFEST}"
    apply_manifests "$SCHEDULE_MANIFEST"
    ok "chaos schedule (monkey) applied — faults will be injected on schedule"
    ;;
  stop)
    ensure_kubeconfig
    step "Chaos stop"
    delete_manifests "$SCHEDULE_MANIFEST"
    delete_manifests "$BRIDGE_MANIFEST"
    ok "chaos schedule + annotation bridge removed"
    ;;
  *)
    die "usage: chaos.sh start|stop"
    ;;
esac
