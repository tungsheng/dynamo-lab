#!/usr/bin/env bash
# scripts/platform.sh  up|down
# Install / remove the in-cluster platform on a live EKS cluster:
#   coordination plane (etcd, NATS) -> Dynamo operator+CRDs ->
#   observability (kube-prometheus-stack, loki, tempo, promtail + dashboards) ->
#   Chaos Mesh -> Karpenter NodePool/EC2NodeClass.
# The Karpenter CONTROLLER helm_release is owned by terraform/main/karpenter.tf;
# this script only applies the NodePool + EC2NodeClass.
#
# Helm values live under platform/<component>/ (values-<chart>.yaml) and are
# passed via values_args, which FAILS LOUDLY if an expected file is missing.
#
# chmod +x scripts/platform.sh
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

require_cmd kubectl helm aws

ACTION="${1:-up}"

# --------------------------------------------------------------------------
# Chart coordinates + pinned versions.
# All version-sensitive; each carries a # VERIFY. Override any via environment.
# --------------------------------------------------------------------------
# Helm repositories (name url) for non-OCI charts.
REPO_PROM="https://prometheus-community.github.io/helm-charts"
REPO_GRAFANA="https://grafana.github.io/helm-charts"
REPO_NATS="https://nats-io.github.io/k8s/helm/charts/"
REPO_CHAOS="https://charts.chaos-mesh.org"

# Coordination plane.
ETCD_CHART="oci://registry-1.docker.io/bitnamicharts/etcd"
ETCD_CHART_VERSION="${ETCD_CHART_VERSION:-10.7.1}"     # VERIFY: bitnami etcd chart version
NATS_CHART_VERSION="${NATS_CHART_VERSION:-1.2.11}"     # VERIFY: nats/nats chart version

# Dynamo operator + CRDs.
# VERIFY: exact chart source for the pinned Dynamo release. NVIDIA publishes the
# Kubernetes Platform either from the repo's deploy/helm dir or an OCI/NGC
# registry — confirm against github.com/ai-dynamo/dynamo for DYNAMO_VERSION.
DYNAMO_HELM_OCI="${DYNAMO_HELM_OCI:-oci://nvcr.io/nvidia/ai-dynamo}"   # VERIFY
DYNAMO_CRDS_CHART="${DYNAMO_CRDS_CHART:-${DYNAMO_HELM_OCI}/dynamo-crds}"        # VERIFY
DYNAMO_OPERATOR_CHART="${DYNAMO_OPERATOR_CHART:-${DYNAMO_HELM_OCI}/dynamo-platform}"  # VERIFY: chart name (dynamo-platform vs dynamo-operator)

# Observability.
KPS_VERSION="${KPS_VERSION:-66.3.1}"          # VERIFY: kube-prometheus-stack chart version
LOKI_VERSION="${LOKI_VERSION:-6.24.0}"        # VERIFY: grafana/loki chart version
TEMPO_VERSION="${TEMPO_VERSION:-1.14.0}"      # VERIFY: grafana/tempo chart version
PROMTAIL_VERSION="${PROMTAIL_VERSION:-6.16.6}" # VERIFY: grafana/promtail chart version

# Chaos Mesh.
CHAOS_VERSION="${CHAOS_VERSION:-2.6.5}"       # VERIFY: chaos-mesh chart version

# Karpenter (controller chart version MUST match the Karpenter IAM/node version
# provisioned by terraform/main's karpenter submodule).
KARPENTER_VERSION="${KARPENTER_VERSION:-1.1.1}"  # VERIFY: karpenter chart version (align with terraform)

HELM_WAIT_TIMEOUT="${HELM_WAIT_TIMEOUT:-10m}"

# --------------------------------------------------------------------------
add_repos() {
  step "Ensuring helm repositories"
  helm repo add prometheus-community "$REPO_PROM"  >/dev/null 2>&1 || true
  helm repo add grafana             "$REPO_GRAFANA" >/dev/null 2>&1 || true
  helm repo add nats                "$REPO_NATS"    >/dev/null 2>&1 || true
  helm repo add chaos-mesh          "$REPO_CHAOS"   >/dev/null 2>&1 || true
  helm repo update >/dev/null
  ok "helm repos ready"
}

create_namespaces() {
  step "Creating namespaces"
  local ns
  for ns in "${ALL_NAMESPACES[@]}"; do
    ensure_namespace "$ns"
    ok "namespace ${ns}"
  done
}

# --- Coordination plane ---------------------------------------------------
install_coordination() {
  step "Coordination plane: etcd (HA, auth disabled) + NATS (JetStream cluster)"

  # etcd: 3-node quorum, no auth (ALLOW_NONE_AUTHENTICATION), metrics on.
  # VERIFY: bitnami relocated images to 'bitnamilegacy'; overriding the repo
  # requires global.security.allowInsecureImages=true. Confirm a working tag.
  # shellcheck disable=SC2046
  helm upgrade --install "$REL_ETCD" "$ETCD_CHART" \
    --version "$ETCD_CHART_VERSION" -n "$NS_DYNAMO" \
    --set replicaCount=3 \
    --set auth.rbac.create=false \
    --set auth.rbac.token.enabled=false \
    --set auth.client.secureTransport=false \
    --set metrics.enabled=true \
    --set image.repository=bitnamilegacy/etcd \
    --set global.security.allowInsecureImages=true \
    --set commonLabels."app\.kubernetes\.io/part-of"=dynamo-lab \
    $(values_args "$PLATFORM_DIR/coordination/values-etcd.yaml") \
    --wait --timeout "$HELM_WAIT_TIMEOUT"
  ok "etcd installed"

  # NATS: clustered (3) with JetStream + monitoring/exporter.
  # VERIFY: nats/nats value keys (config.cluster.*, config.jetstream.*,
  # config.monitor.enabled, promExporter.enabled) for the pinned chart version.
  # shellcheck disable=SC2046
  helm upgrade --install "$REL_NATS" nats/nats \
    --version "$NATS_CHART_VERSION" -n "$NS_DYNAMO" \
    --set config.cluster.enabled=true \
    --set config.cluster.replicas=3 \
    --set config.jetstream.enabled=true \
    --set config.monitor.enabled=true \
    --set promExporter.enabled=true \
    --set natsBox.enabled=false \
    $(values_args "$PLATFORM_DIR/coordination/values-nats.yaml") \
    --wait --timeout "$HELM_WAIT_TIMEOUT"
  ok "nats installed"
}

# --- Dynamo operator ------------------------------------------------------
install_operator() {
  step "Dynamo operator + CRDs (ns ${NS_DYNAMO_SYSTEM})"

  # CRDs first, then the platform/operator chart. The CRDs chart ships no lab
  # values overrides, so no -f flags here.
  helm upgrade --install "$REL_DYNAMO_CRDS" "$DYNAMO_CRDS_CHART" \
    --version "$DYNAMO_VERSION" -n "$NS_DYNAMO_SYSTEM" \
    --wait --timeout "$HELM_WAIT_TIMEOUT"
  ok "dynamo CRDs installed"

  # shellcheck disable=SC2046
  helm upgrade --install "$REL_DYNAMO_OPERATOR" "$DYNAMO_OPERATOR_CHART" \
    --version "$DYNAMO_VERSION" -n "$NS_DYNAMO_SYSTEM" \
    $(values_args "$PLATFORM_DIR/operator/values-dynamo-platform.yaml") \
    --wait --timeout "$HELM_WAIT_TIMEOUT"
  ok "dynamo operator installed"
}

# --- Observability --------------------------------------------------------
install_observability() {
  step "Observability: kube-prometheus-stack, loki, tempo, promtail (ns ${NS_MONITORING})"

  # kube-prometheus-stack: remote-write receiver ON (k6 pushes here), and
  # ServiceMonitor/PodMonitor discovery across all namespaces.
  # shellcheck disable=SC2046
  helm upgrade --install "$REL_KPS" prometheus-community/kube-prometheus-stack \
    --version "$KPS_VERSION" -n "$NS_MONITORING" \
    --set prometheus.prometheusSpec.enableRemoteWriteReceiver=true \
    --set prometheus.prometheusSpec.serviceMonitorSelectorNilUsesHelmValues=false \
    --set prometheus.prometheusSpec.podMonitorSelectorNilUsesHelmValues=false \
    $(values_args "$PLATFORM_DIR/observability/values-kube-prometheus-stack.yaml") \
    --wait --timeout "$HELM_WAIT_TIMEOUT"
  ok "kube-prometheus-stack installed"

  # Loki: single-binary / monolithic mode for a lab.
  # shellcheck disable=SC2046
  helm upgrade --install "$REL_LOKI" grafana/loki \
    --version "$LOKI_VERSION" -n "$NS_MONITORING" \
    $(values_args "$PLATFORM_DIR/observability/values-loki.yaml") \
    --wait --timeout "$HELM_WAIT_TIMEOUT"
  ok "loki installed"

  # Tempo: single-binary, OTLP receivers on 4317/4318.
  # shellcheck disable=SC2046
  helm upgrade --install "$REL_TEMPO" grafana/tempo \
    --version "$TEMPO_VERSION" -n "$NS_MONITORING" \
    $(values_args "$PLATFORM_DIR/observability/values-tempo.yaml") \
    --wait --timeout "$HELM_WAIT_TIMEOUT"
  ok "tempo installed"

  # Promtail: ships pod logs to Loki. (Grafana Alloy is the modern successor;
  # promtail is fine for a lab and simpler to reason about.)
  # shellcheck disable=SC2046
  helm upgrade --install "$REL_PROMTAIL" grafana/promtail \
    --version "$PROMTAIL_VERSION" -n "$NS_MONITORING" \
    $(values_args "$PLATFORM_DIR/observability/values-promtail.yaml") \
    --wait --timeout "$HELM_WAIT_TIMEOUT"
  ok "promtail installed"

  # Grafana dashboard ConfigMaps (sidecar-discovered). They live in two spots:
  #   platform/observability/grafana/dashboards/*.yaml       (per-signal dashboards)
  #   platform/observability/grafana/lab-overview-dashboard-configmap.yaml
  if [[ -d "$PLATFORM_DIR/observability/grafana/dashboards" ]]; then
    log "applying Grafana dashboard ConfigMaps"
    apply_manifests "$PLATFORM_DIR/observability/grafana/dashboards"
    apply_manifests "$PLATFORM_DIR/observability/grafana/lab-overview-dashboard-configmap.yaml"
    ok "dashboards applied"
  else
    warn "no platform/observability/grafana/dashboards directory — skipping dashboard ConfigMaps"
  fi
}

# --- Chaos Mesh -----------------------------------------------------------
install_chaos_mesh() {
  step "Chaos Mesh (ns ${NS_CHAOS})"
  # Dashboard + Prometheus metrics enabled.
  # shellcheck disable=SC2046
  helm upgrade --install "$REL_CHAOS" chaos-mesh/chaos-mesh \
    --version "$CHAOS_VERSION" -n "$NS_CHAOS" \
    --set dashboard.create=true \
    --set prometheus.enabled=true \
    $(values_args "$PLATFORM_DIR/chaos-mesh/values.yaml") \
    --wait --timeout "$HELM_WAIT_TIMEOUT"
  ok "chaos-mesh installed"
}

# --- Karpenter ------------------------------------------------------------
# The Karpenter CONTROLLER (helm_release) is installed by terraform/main/karpenter.tf
# (Terraform owns it, wired via EKS Pod Identity). Here we ONLY apply the NodePool +
# EC2NodeClass so node shapes can be tweaked without a terraform run.
install_karpenter() {
  step "Karpenter NodePool/EC2NodeClass (ns ${NS_KARPENTER})"

  # EC2NodeClass.spec.role is rendered from the terraform node IAM role output.
  # VERIFY: this output name matches terraform/main.
  KARPENTER_NODE_ROLE="$(tf_output karpenter_node_iam_role_name)"
  export CLUSTER_NAME KARPENTER_NODE_ROLE
  # Alias for manifests that use the module's own output name verbatim.
  export KARPENTER_NODE_IAM_ROLE_NAME="$KARPENTER_NODE_ROLE"

  [[ -n "$KARPENTER_NODE_ROLE" ]] || warn "karpenter_node_iam_role_name empty — EC2NodeClass will not resolve a node role (is terraform/main applied?)"

  # NodePool + EC2NodeClass are plain manifests applied by us (not terraform).
  # ${CLUSTER_NAME} / ${KARPENTER_NODE_ROLE} placeholders are rendered via envsubst.
  log "applying Karpenter NodePool / EC2NodeClass"
  apply_manifests "$PLATFORM_DIR/karpenter"
  ok "karpenter NodePool/EC2NodeClass applied"
}

# --------------------------------------------------------------------------
platform_up() {
  ensure_kubeconfig
  add_repos
  create_namespaces
  install_coordination
  install_operator
  install_observability
  install_chaos_mesh
  install_karpenter
  step "Platform up complete"
  ok "coordination + operator + observability + chaos-mesh + karpenter ready"
}

platform_down() {
  ensure_kubeconfig
  step "Removing platform (best-effort, reverse order)"

  # Remove Karpenter-provisioned nodes cleanly (nodeclaim finalizers drain/
  # terminate the instances), then the NodePool/EC2NodeClass we applied. The
  # controller helm_release is Terraform-owned (terraform/main/karpenter.tf), so
  # it is NOT uninstalled here — terraform destroy (make infra-down) removes it.
  kubectl delete nodeclaims --all --ignore-not-found >/dev/null 2>&1 || true
  delete_manifests "$PLATFORM_DIR/karpenter"

  helm_uninstall "$REL_CHAOS" "$NS_CHAOS"

  helm_uninstall "$REL_PROMTAIL" "$NS_MONITORING"
  helm_uninstall "$REL_TEMPO" "$NS_MONITORING"
  helm_uninstall "$REL_LOKI" "$NS_MONITORING"
  helm_uninstall "$REL_KPS" "$NS_MONITORING"

  helm_uninstall "$REL_DYNAMO_OPERATOR" "$NS_DYNAMO_SYSTEM"
  helm_uninstall "$REL_DYNAMO_CRDS" "$NS_DYNAMO_SYSTEM"

  helm_uninstall "$REL_NATS" "$NS_DYNAMO"
  helm_uninstall "$REL_ETCD" "$NS_DYNAMO"

  step "Platform down complete"
  ok "helm releases removed (namespaces left in place)"
}

case "$ACTION" in
  up)   platform_up ;;
  down) platform_down ;;
  *)    die "usage: platform.sh up|down" ;;
esac
