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

require_cmd kubectl helm aws envsubst

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
# HELD at 10.7.1 (not bumped to the current 12.x): newer charts pin an etcd image tag that is
# absent from the FROZEN docker.io/bitnamilegacy archive, so a bump breaks the anonymous-pull
# fallback below. Renders clean on K8s 1.36 and the pinned legacy image is verified present
# (see install_coordination). Verified 2026-07-27.
ETCD_CHART_VERSION="${ETCD_CHART_VERSION:-10.7.1}"
# nats/nats 2.14.2 — latest; the config.*/promExporter value schema is unchanged from 1.x
# (render-verified against K8s 1.36 with the flags/values below). Verified 2026-07-27.
NATS_CHART_VERSION="${NATS_CHART_VERSION:-2.14.2}"

# Dynamo operator (+ CRDs, which ship inside the operator image).
# Verified v1.3.0: NGC serves the chart over HTTPS (`helm repo add`), NOT oci:// — see
# platform/operator/README.md + values-dynamo-platform.yaml. The repo is added in
# add_repos() and the chart is installed by reference (<repo>/<chart>) in install_operator.
# As of v1.3.0 there is NO standalone dynamo-crds chart: the operator's crd-apply init
# container applies the CRDs, so only dynamo-platform is installed.
REPO_DYNAMO="${REPO_DYNAMO:-https://helm.ngc.nvidia.com/nvidia/ai-dynamo}"
DYNAMO_OPERATOR_CHART="${DYNAMO_OPERATOR_CHART:-nvidia-ai-dynamo/dynamo-platform}"

# Observability.
# All four bumped to latest and render-verified against K8s 1.36 with the values/flags below;
# the old pins predated 1.36 (e.g. the kube-prometheus-stack 66.x Prometheus operator). The
# NATS/Loki/KPS jumps cross a chart major but the values keys we set still resolve. 2026-07-27.
KPS_VERSION="${KPS_VERSION:-87.20.0}"          # kube-prometheus-stack (was 66.3.1)
LOKI_VERSION="${LOKI_VERSION:-7.1.0}"          # grafana/loki (was 6.24.0, chart major 6->7)
TEMPO_VERSION="${TEMPO_VERSION:-1.24.4}"       # grafana/tempo (was 1.14.0)
PROMTAIL_VERSION="${PROMTAIL_VERSION:-6.17.1}" # grafana/promtail (was 6.16.6; promtail is EOL, Alloy is the successor)

# Chaos Mesh.
CHAOS_VERSION="${CHAOS_VERSION:-2.8.3}"       # chaos-mesh (was 2.6.5); latest, render-verified on K8s 1.36. 2026-07-27

# Track G — Grove + KAI-Scheduler (OPT-IN; installed only when GROVE=1). Both are OCI charts, so
# no `helm repo add`. Pins verified vs the Dynamo v1.3.0 compat matrix (platform/grove/README.md,
# ADR docs/adr/0009-track-g-grove-gang-scheduling.md): Grove >= v0.1.0-alpha.11 for
# dynamo-platform 1.3.x; KAI >= v0.13.4 (>= v0.15.2 enables topology-aware placement).
# VERIFY (live): render both charts with `helm template` on K8s 1.36 before relying on them.
GROVE="${GROVE:-0}"
GROVE_CHART="${GROVE_CHART:-oci://ghcr.io/ai-dynamo/grove/grove-charts}"
GROVE_VERSION="${GROVE_VERSION:-v0.1.0-alpha.11}"
KAI_CHART="${KAI_CHART:-oci://ghcr.io/kai-scheduler/kai-scheduler/kai-scheduler}"
KAI_VERSION="${KAI_VERSION:-v0.15.2}"

# NOTE: the Karpenter controller chart version is NOT pinned here — Terraform owns the
# controller helm_release (terraform/main/karpenter.tf, chart 1.0.8). This script only
# applies the NodePool + EC2NodeClass.

HELM_WAIT_TIMEOUT="${HELM_WAIT_TIMEOUT:-10m}"

# --------------------------------------------------------------------------
add_repos() {
  step "Ensuring helm repositories"
  helm repo add prometheus-community "$REPO_PROM"  >/dev/null 2>&1 || true
  helm repo add grafana             "$REPO_GRAFANA" >/dev/null 2>&1 || true
  helm repo add nats                "$REPO_NATS"    >/dev/null 2>&1 || true
  helm repo add chaos-mesh          "$REPO_CHAOS"   >/dev/null 2>&1 || true
  # NGC Dynamo charts over HTTPS (public, anonymous-pullable) — NOT an oci:// registry.
  helm repo add nvidia-ai-dynamo    "$REPO_DYNAMO"  >/dev/null 2>&1 || true
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

# --- Default StorageClass -------------------------------------------------
# Cluster-scoped gp3 default so every persistence PVC (etcd, NATS, Prometheus, Loki, Tempo)
# binds to an encrypted gp3 volume instead of an implicit/absent default. EKS's ebs-csi addon
# ships no default StorageClass, so this must exist BEFORE any chart with persistence.
install_storageclass() {
  step "Default StorageClass (gp3, encrypted)"
  apply_manifests "$PLATFORM_DIR/storageclass-gp3.yaml"
  ok "gp3 StorageClass applied"
}

# --- Coordination plane ---------------------------------------------------
install_coordination() {
  step "Coordination plane: etcd (HA, auth disabled) + NATS (JetStream cluster)"

  # etcd: 3-node quorum, no auth (ALLOW_NONE_AUTHENTICATION), metrics on.
  # Bitnami relocated free image tags to docker.io/bitnamilegacy (Aug 2025), so we override the
  # repo and set global.security.allowInsecureImages=true. The pinned tag
  # bitnamilegacy/etcd:3.5.21-debian-12-r5 (values-etcd.yaml) is verified present + anonymously
  # pullable (Docker Hub, 2026-07-27).
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

# --- Grove + KAI-Scheduler (Track G, opt-in) ------------------------------
# Installed ONLY when GROVE=1 (default off), so the standard bring-up is byte-identical to today.
# Grove is Dynamo's gang-scheduling / multi-component orchestration operator; KAI is the gang
# scheduler it relies on. Both are OCI charts (CRDs ship inside the Grove chart). install_operator()
# additionally sets global.grove.enabled + global.kai-scheduler.enabled when GROVE=1, after which
# the operator renders DGDs as Grove PodCliqueSets. See platform/grove/README.md + ADR 0009.
install_grove() {
  step "Track G: Grove operator + KAI-Scheduler (opt-in, GROVE=1)"

  # shellcheck disable=SC2046
  helm upgrade --install "$REL_GROVE" "$GROVE_CHART" \
    --version "$GROVE_VERSION" -n "$NS_GROVE" --create-namespace \
    $(values_args "$PLATFORM_DIR/grove/values-grove-operator.yaml") \
    --wait --timeout "$HELM_WAIT_TIMEOUT"
  ok "grove operator installed (${GROVE_VERSION})"

  # shellcheck disable=SC2046
  helm upgrade --install "$REL_KAI" "$KAI_CHART" \
    --version "$KAI_VERSION" -n "$NS_KAI" --create-namespace \
    $(values_args "$PLATFORM_DIR/grove/values-kai-scheduler.yaml") \
    --wait --timeout "$HELM_WAIT_TIMEOUT"
  ok "kai-scheduler installed (${KAI_VERSION})"

  # Track G observability (opt-in): a PodMonitor for the scheduler internals + a Grafana dashboard
  # for gang state. Needs the PodMonitor CRD + Grafana sidecar from kube-prometheus-stack, which is
  # installed before Grove in platform_up (and assumed already up on the grove-up path).
  log "applying Track G observability (PodMonitor + Grafana dashboard)"
  apply_manifests "$PLATFORM_DIR/grove/podmonitor-grove.yaml"
  apply_manifests "$PLATFORM_DIR/grove/grafana-grove-dashboard-configmap.yaml"
  ok "grove observability applied"
}

# grove_operator_flags — echo the extra operator --set flags that turn on Grove/KAI integration
# when GROVE=1, and nothing otherwise. Mirrors the values_args idiom (word-split into the helm
# command under the SC2046 disable), so the operator install is unchanged when GROVE=0.
grove_operator_flags() {
  [[ "$GROVE" == "1" ]] || return 0
  printf -- '--set global.grove.enabled=true --set global.kai-scheduler.enabled=true'
}

# grove_down — best-effort removal of ALL of Track G: the Grove/KAI controllers AND the
# observability resources install_grove() applied into the `monitoring` namespace (a PodMonitor +
# a Grafana dashboard ConfigMap). Those live in `monitoring`, which survives both platform-down and
# track-g-down and is owned by no release we uninstall, so they must be deleted explicitly or they
# orphan. No-op when never installed (helm_uninstall guards on `helm status`; delete_manifests is
# --ignore-not-found and `|| true`), so it is safe to call on every platform teardown.
grove_down() {
  helm_uninstall "$REL_KAI" "$NS_KAI"
  helm_uninstall "$REL_GROVE" "$NS_GROVE"
  delete_manifests "$PLATFORM_DIR/grove/podmonitor-grove.yaml"
  delete_manifests "$PLATFORM_DIR/grove/grafana-grove-dashboard-configmap.yaml"
}

# --- Dynamo operator ------------------------------------------------------
install_operator() {
  step "Dynamo operator + CRDs (ns ${NS_DYNAMO_SYSTEM})"

  # Verified v1.3.0: install only the dynamo-platform chart. The operator image's crd-apply
  # init container applies the DynamoGraphDeployment CRDs (dynamo-operator.upgradeCRD defaults
  # to true), so there is no separate dynamo-crds chart to install first.
  # Track G: grove_operator_flags adds global.grove.enabled + global.kai-scheduler.enabled when
  # GROVE=1 (empty otherwise — default install unchanged).
  # shellcheck disable=SC2046
  helm upgrade --install "$REL_DYNAMO_OPERATOR" "$DYNAMO_OPERATOR_CHART" \
    --version "$DYNAMO_PLATFORM_VERSION" -n "$NS_DYNAMO_SYSTEM" \
    $(grove_operator_flags) \
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

  # Fleet PodMonitor: the operator ships none for the mocker fleet, so we provide one.
  log "applying fleet PodMonitor"
  apply_manifests "$PLATFORM_DIR/observability/podmonitor-fleet.yaml"
  ok "fleet PodMonitor applied"
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
    $(values_args "$PLATFORM_DIR/chaos-mesh/values-chaos-mesh.yaml") \
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
  install_storageclass
  add_repos
  create_namespaces
  # Observability MUST come first: kube-prometheus-stack installs the Prometheus Operator CRDs
  # (PodMonitor / ServiceMonitor / monitoring.coreos.com). etcd, NATS, the operator, and
  # chaos-mesh below all create PodMonitors/ServiceMonitors, which fail to apply ("no matches
  # for kind PodMonitor") if those CRDs don't exist yet. Diagnosed live 2026-07-28.
  install_observability
  install_coordination
  # Track G (opt-in): install Grove + KAI-Scheduler BEFORE the operator, so install_operator can
  # integrate with them (it sets global.grove.enabled when GROVE=1). No-op unless GROVE=1, so the
  # default bring-up is unchanged.
  if [[ "$GROVE" == "1" ]]; then install_grove; fi
  install_operator
  install_chaos_mesh
  install_karpenter
  step "Platform up complete"
  if [[ "$GROVE" == "1" ]]; then
    ok "observability + coordination + grove/kai + operator + chaos-mesh + karpenter ready"
  else
    ok "observability + coordination + operator + chaos-mesh + karpenter ready"
  fi
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

  # Track G controllers — best-effort, no-op if Track G was never installed.
  grove_down

  helm_uninstall "$REL_NATS" "$NS_DYNAMO"
  helm_uninstall "$REL_ETCD" "$NS_DYNAMO"

  step "Platform down complete"
  ok "helm releases removed (namespaces left in place)"
}

case "$ACTION" in
  up)   platform_up ;;
  down) platform_down ;;
  # Track G (opt-in): add/remove Grove + KAI on an ALREADY-RUNNING base platform, without
  # touching observability/coordination/chaos/karpenter. `make track-g-up`/`track-g-down` wrap
  # these with the grove-scale fleet overlay. Enabling flips the operator to the Grove path.
  grove-up)
    GROVE=1
    ensure_kubeconfig
    install_grove
    install_operator   # re-render the operator WITH global.grove.enabled (grove_operator_flags)
    step "Track G platform ready"
    ok "grove + kai installed; operator integrated — deploy the fleet with PROFILE=grove-scale"
    ;;
  grove-down)
    GROVE=0
    ensure_kubeconfig
    install_operator   # re-render the operator WITHOUT grove flags (disables the integration)
    grove_down         # uninstall the KAI + Grove controllers (best-effort)
    step "Track G platform removed"
    ok "operator reverted to the default path; grove + kai uninstalled"
    ;;
  *)    die "usage: platform.sh up|down|grove-up|grove-down" ;;
esac
