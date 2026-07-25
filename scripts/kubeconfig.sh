#!/usr/bin/env bash
# scripts/kubeconfig.sh
# Point kubectl at the EKS cluster and print a quick sanity check.
#
# chmod +x scripts/kubeconfig.sh
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

step "Kubeconfig"
ensure_kubeconfig

log "cluster nodes:"
kubectl get nodes -o wide || warn "no nodes visible yet (they may still be joining)"
