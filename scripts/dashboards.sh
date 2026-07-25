#!/usr/bin/env bash
# scripts/dashboards.sh
# Port-forward Grafana and print the URL + credential hint.
# Runs in the foreground; Ctrl-C to stop the port-forward.
#
# chmod +x scripts/dashboards.sh
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

require_cmd kubectl
ensure_kubeconfig

GRAFANA_SVC="kube-prometheus-stack-grafana"
LOCAL_PORT="${GRAFANA_LOCAL_PORT:-3000}"

step "Grafana dashboards"

# Best-effort: surface the admin credentials from the chart-managed secret.
GF_USER="$(kubectl -n "$NS_MONITORING" get secret "$GRAFANA_SVC" \
  -o jsonpath='{.data.admin-user}' 2>/dev/null | base64 --decode 2>/dev/null || true)"
GF_PASS="$(kubectl -n "$NS_MONITORING" get secret "$GRAFANA_SVC" \
  -o jsonpath='{.data.admin-password}' 2>/dev/null | base64 --decode 2>/dev/null || true)"

log "URL : http://localhost:${LOCAL_PORT}"
log "user: ${GF_USER:-admin}"
if [[ -n "$GF_PASS" ]]; then
  log "pass: ${GF_PASS}"
else
  log "pass: (kube-prometheus-stack default is 'prom-operator')"
fi
log "port-forwarding kube-prometheus-stack-grafana — press Ctrl-C to stop"

exec kubectl -n "$NS_MONITORING" port-forward "svc/${GRAFANA_SVC}" "${LOCAL_PORT}:80"
