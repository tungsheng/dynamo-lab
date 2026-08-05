# shellcheck shell=bash
# shellcheck disable=SC2034  # config vars below are the source of truth, consumed by the scripts that source this file
# scripts/lib/common.sh
# Shared environment + helpers for every dynamo-lab script.
# SOURCE this file ("source .../lib/common.sh"); do not execute it directly.
#
# All names/paths/versions here are the single source of truth for the scripts
# layer and MUST match the SHARED SPEC. Override anything via environment.

# Guard against double-sourcing.
if [[ -n "${_DYNAMO_LAB_COMMON_SOURCED:-}" ]]; then
  return 0 2>/dev/null || true
fi
_DYNAMO_LAB_COMMON_SOURCED=1

set -euo pipefail

# --------------------------------------------------------------------------
# Paths
# --------------------------------------------------------------------------
# This file lives at scripts/lib/common.sh -> repo root is two levels up.
_COMMON_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${_COMMON_LIB_DIR}/../.." && pwd)"
export REPO_ROOT

SCRIPTS_DIR="${REPO_ROOT}/scripts"
TF_MAIN_DIR="${REPO_ROOT}/terraform/main"
TF_BOOTSTRAP_DIR="${REPO_ROOT}/terraform/bootstrap"
PLATFORM_DIR="${REPO_ROOT}/platform"
FLEET_DIR="${REPO_ROOT}/fleet"
CHAOS_DIR="${REPO_ROOT}/chaos"
LOAD_DIR="${REPO_ROOT}/load"
# Benchmarks tree (opt-in; ADR 0010). The first unit is benchmarks/router/.
BENCH_DIR="${REPO_ROOT}/benchmarks"

# --------------------------------------------------------------------------
# Core AWS / cluster settings (all overridable)
# --------------------------------------------------------------------------
REGION="${REGION:-us-west-2}"
# The AWS CLI honours AWS_REGION; keep it in sync with our REGION.
export AWS_REGION="${AWS_REGION:-$REGION}"
export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-$REGION}"

CLUSTER_NAME="${CLUSTER_NAME:-dynamo-lab}"

# Project name — used to derive the Terraform state bucket. MUST match terraform's
# `project` var default (terraform/bootstrap/main.tf computes ${project}-tfstate-<acct>).
PROJECT="${PROJECT:-dynamo-lab}"

# Pinned Dynamo MOCKER IMAGE tag. Shared with fleet manifests via env. This is the
# container image tag ONLY — the Dynamo platform helm chart versions independently (below).
# Verified v1.3.0: nvcr.io/nvidia/ai-dynamo/dynamo-planner:1.3.0 ships the dynamo.mocker
# module and runs CPU-only (docs/dynosim/mocker.md; examples/backends/mocker/deploy/agg.yaml).
DYNAMO_VERSION="${DYNAMO_VERSION:-1.3.0}"
export DYNAMO_VERSION

# Dynamo platform helm CHART version — independent of DYNAMO_VERSION (the mocker image tag).
# Verified v1.3.0 (deploy/helm/charts/platform/Chart.yaml: name dynamo-platform, version 1.3.0).
# The standalone dynamo-crds chart is GONE as of v1.3.0 — the operator image applies the CRDs
# via its crd-apply init container, so there is no separate CRDs chart/version to pin.
DYNAMO_PLATFORM_VERSION="${DYNAMO_PLATFORM_VERSION:-1.3.0}"

# --------------------------------------------------------------------------
# Load-test fleet topology selector (INDEPENDENT of the k6 traffic PROFILE)
# --------------------------------------------------------------------------
# TOPOLOGY picks which deployed fleet the load runner targets: agg | disagg.
# Verified v1.3.0: the operator names the frontend Service "<dgd-name>-frontend" on :8000
# (operator graph.go GetDCDResourceName + the Frontend service case). Our DGDs are
# mocker-agg / mocker-disagg (fleet/agg.yaml, fleet/disagg.yaml), so the frontend Service is
# mocker-<topology>-frontend on :8000. FRONTEND_URL may also be overridden directly (e.g. for
# a port-forward).
TOPOLOGY="${TOPOLOGY:-agg}"
FRONTEND_URL="${FRONTEND_URL:-http://mocker-${TOPOLOGY}-frontend.dynamo.svc.cluster.local:8000}"

# Common labels applied to first-party resources we create imperatively.
PART_OF_LABEL="app.kubernetes.io/part-of=dynamo-lab"

# --------------------------------------------------------------------------
# Namespaces (exact — see SHARED SPEC)
# --------------------------------------------------------------------------
NS_DYNAMO_SYSTEM="dynamo-system"   # Dynamo operator + CRDs
NS_DYNAMO="dynamo"                 # fleet + coordination plane (etcd, NATS)
NS_MONITORING="monitoring"         # kube-prometheus-stack, loki, tempo, promtail
NS_CHAOS="chaos-mesh"              # Chaos Mesh
NS_KARPENTER="karpenter"           # Karpenter controller
NS_LOAD="load"                     # k6 runner

# Track G (opt-in) — Grove operator + KAI-Scheduler. Deliberately NOT in ALL_NAMESPACES so the
# default bring-up never creates them; install_grove() creates them with helm --create-namespace
# only when GROVE=1.
NS_GROVE="grove-system"            # Grove operator (Track G)
NS_KAI="kai-scheduler"             # KAI-Scheduler gang scheduler (Track G)

# Ordered list used for bulk namespace creation.
ALL_NAMESPACES=(
  "$NS_DYNAMO_SYSTEM"
  "$NS_DYNAMO"
  "$NS_MONITORING"
  "$NS_CHAOS"
  "$NS_KARPENTER"
  "$NS_LOAD"
)

# --------------------------------------------------------------------------
# Helm release names (exact — see SHARED SPEC)
# --------------------------------------------------------------------------
REL_DYNAMO_OPERATOR="dynamo-operator"
REL_KPS="kube-prometheus-stack"
REL_LOKI="loki"
REL_TEMPO="tempo"
REL_PROMTAIL="promtail"
REL_ETCD="etcd"
REL_NATS="nats"
REL_CHAOS="chaos-mesh"
REL_KARPENTER="karpenter"

# Track G (opt-in) — see platform/grove/ + platform.sh install_grove().
REL_GROVE="grove"
REL_KAI="kai-scheduler"

# --------------------------------------------------------------------------
# Terraform state (S3 backend, native locking) — see SHARED SPEC / ADR 0006
# --------------------------------------------------------------------------
TF_STATE_KEY="main/terraform.tfstate"
# Bucket name is deterministic: <PROJECT>-tfstate-<AWS_ACCOUNT_ID>.
# Computed lazily via state_bucket() because it needs the account id.

# --------------------------------------------------------------------------
# Template rendering whitelist
# --------------------------------------------------------------------------
# Only these ${VAR} references are substituted when we render manifests, so we
# never accidentally mangle other '$' occurrences in third-party YAML. Pruned to the
# vars actually referenced by a manifest (verified by grepping platform/ fleet/ chaos/ load/).
# Only tokens that appear as ${VAR} in a manifest belong here. The k6 job's env
# block uses distinct ${K6_*} tokens so envsubst never rewrites the identical
# ${PROFILE}/${FRONTEND_URL}/${MODEL} JavaScript template literals in the embedded
# k6 script (those are resolved by the k6 runtime from __ENV, not at render time).
# ${BENCH_ARM}/${BENCH_FRONTEND_URL} are the router-benchmark tokens (scripts/bench.sh,
# benchmarks/router/*), kept distinct from the ${K6_*} tokens for the same reason.
RENDER_VARS='${CLUSTER_NAME} ${DYNAMO_VERSION} ${K6_PROFILE} ${K6_FRONTEND_URL} ${KARPENTER_NODE_ROLE} ${BENCH_ARM} ${BENCH_FRONTEND_URL}'

# --------------------------------------------------------------------------
# Logging helpers
# --------------------------------------------------------------------------
if [[ -t 1 ]]; then
  _C_RESET="\033[0m"; _C_BLUE="\033[34m"; _C_GREEN="\033[32m"
  _C_YELLOW="\033[33m"; _C_RED="\033[31m"; _C_BOLD="\033[1m"
else
  _C_RESET=""; _C_BLUE=""; _C_GREEN=""; _C_YELLOW=""; _C_RED=""; _C_BOLD=""
fi

log()  { printf "${_C_BLUE}==>${_C_RESET} %s\n" "$*"; }
ok()   { printf "${_C_GREEN}  ok${_C_RESET} %s\n" "$*"; }
warn() { printf "${_C_YELLOW}  !!${_C_RESET} %s\n" "$*" >&2; }
die()  { printf "${_C_RED}ERROR${_C_RESET} %s\n" "$*" >&2; exit 1; }
step() { printf "\n${_C_BOLD}%s${_C_RESET}\n" "$*"; }

# --------------------------------------------------------------------------
# Small utilities
# --------------------------------------------------------------------------
have() { command -v "$1" >/dev/null 2>&1; }

# require_cmd <cmd> [<cmd> ...] — fail early if a required binary is missing.
require_cmd() {
  local missing=()
  local c
  for c in "$@"; do
    have "$c" || missing+=("$c")
  done
  if ((${#missing[@]})); then
    die "missing required command(s): ${missing[*]}"
  fi
}

# aws_account_id — cached lookup of the caller's account id.
aws_account_id() {
  if [[ -z "${_AWS_ACCOUNT_ID:-}" ]]; then
    require_cmd aws
    _AWS_ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)" \
      || die "unable to resolve AWS account id (is your AWS auth configured?)"
    export _AWS_ACCOUNT_ID
  fi
  printf '%s' "$_AWS_ACCOUNT_ID"
}

# state_bucket — deterministic Terraform state bucket name. Matches the name that
# terraform/bootstrap computes: ${var.project}-tfstate-<account_id>.
state_bucket() {
  printf '%s-tfstate-%s' "$PROJECT" "$(aws_account_id)"
}

# ensure_kubeconfig — point kubectl at the EKS cluster (idempotent).
ensure_kubeconfig() {
  require_cmd aws kubectl
  log "updating kubeconfig for cluster '${CLUSTER_NAME}' (${REGION})"
  aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$REGION" >/dev/null \
    || die "aws eks update-kubeconfig failed — is the cluster up? (make infra-up)"
  kubectl config current-context >/dev/null 2>&1 \
    || die "kubectl has no current context after update-kubeconfig"
  ok "kubectl context ready"
}

# tf_output <name> — read a raw output from terraform/main (empty if absent).
tf_output() {
  terraform -chdir="$TF_MAIN_DIR" output -raw "$1" 2>/dev/null || true
}

# ensure_namespace <ns> — create (if absent) and label a namespace.
ensure_namespace() {
  local ns="$1"
  kubectl create namespace "$ns" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  kubectl label namespace "$ns" "$PART_OF_LABEL" --overwrite >/dev/null
}

# render — pass stdin through envsubst restricted to RENDER_VARS.
# envsubst is REQUIRED: manifests like ec2nodeclass.yaml / k6-job.yaml carry ${VAR}
# placeholders that MUST be expanded. A silent `cat` fallback would apply them with
# literal, unexpanded placeholders (a broken node role, a broken frontend URL), so we
# fail loudly instead.
render() {
  have envsubst || die "envsubst not found — install gettext (macOS: brew install gettext; Debian/Ubuntu: apt-get install gettext-base)"
  envsubst "$RENDER_VARS"
}

# apply_manifests <path> — kubectl apply a file, or every *.yaml/*.yml in a
# directory (skipping helm values files), after rendering ${VAR} placeholders.
apply_manifests() {
  local target="$1"
  if [[ -f "$target" ]]; then
    render < "$target" | kubectl apply -f -
    return
  fi
  if [[ -d "$target" ]]; then
    local f found=0
    shopt -s nullglob
    for f in "$target"/*.yaml "$target"/*.yml; do
      case "$(basename "$f")" in
        *values*) continue ;;
        *example*) continue ;;   # e.g. secret.example.yaml — a placeholder to copy, not apply
      esac
      render < "$f" | kubectl apply -f -
      found=1
    done
    shopt -u nullglob
    ((found)) || warn "no manifests found under ${target}"
    return
  fi
  warn "manifest path not found: ${target}"
}

# delete_manifests <path> — best-effort inverse of apply_manifests.
delete_manifests() {
  local target="$1"
  if [[ -f "$target" ]]; then
    render < "$target" | kubectl delete --ignore-not-found -f - || true
    return
  fi
  if [[ -d "$target" ]]; then
    local f
    shopt -s nullglob
    for f in "$target"/*.yaml "$target"/*.yml; do
      case "$(basename "$f")" in
        *values*) continue ;;
        *example*) continue ;;   # e.g. secret.example.yaml — a placeholder to copy, not apply
      esac
      render < "$f" | kubectl delete --ignore-not-found -f - || true
    done
    shopt -u nullglob
    return
  fi
}

# values_args <file> [<file> ...] — echo "-f <file>" for each file.
# Usage:  helm ... $(values_args "$PLATFORM_DIR/observability/values-loki.yaml")
# FAIL LOUDLY on a missing file: a values path that doesn't exist means the
# caller has the wrong path (a bug), NOT "fall back to chart defaults" — the old
# silent `[[ -f "$f" ]] &&` drop let exactly that class of bug hide. Because this
# runs inside a $(...) command substitution, `exit` alone only leaves the
# subshell; `kill "$$"` signals the parent script so the whole run aborts.
values_args() {
  local f out=""
  for f in "$@"; do
    if [[ ! -f "$f" ]]; then
      printf "${_C_RED}ERROR${_C_RESET} expected Helm values file not found: %s\n" "$f" >&2
      kill "$$" 2>/dev/null
      exit 1
    fi
    out+=" -f $f"
  done
  printf '%s' "$out"
}

# helm_uninstall <release> <namespace> — best-effort uninstall.
helm_uninstall() {
  local rel="$1" ns="$2"
  if helm status "$rel" -n "$ns" >/dev/null 2>&1; then
    log "uninstalling helm release '${rel}' (ns ${ns})"
    helm uninstall "$rel" -n "$ns" --wait --timeout 5m || warn "uninstall of ${rel} reported errors"
  fi
}
