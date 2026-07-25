#!/usr/bin/env bash
# scripts/up.sh
# Full lab bring-up, in the layer order from the spec:
#   bootstrap -> infra-up (terraform main) -> kubeconfig ->
#   platform-up -> fleet-up PROFILE=agg
#
# ~15-20 min and a few dollars per cycle; `make down` returns idle cost to $0.
#
# chmod +x scripts/up.sh
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

step "dynamo-lab UP — full bring-up"
log "region=${REGION} cluster=${CLUSTER_NAME}"

"$SCRIPTS_DIR/bootstrap.sh"
"$SCRIPTS_DIR/infra.sh" up
"$SCRIPTS_DIR/kubeconfig.sh"
"$SCRIPTS_DIR/platform.sh" up
# The lab always brings up on the aggregated topology (ADR 0007).
"$SCRIPTS_DIR/fleet.sh" up agg

step "dynamo-lab is UP"
ok "next: 'make dashboards' (Grafana), 'make load-start', 'make chaos-start'"
ok "switch topology with: make fleet-up PROFILE=disagg"
