#!/usr/bin/env bash
# scripts/bench.sh  up|run|down|sweep  [arm]
#
# Router benchmark (ADR 0010 -> benchmarks/router/). Deploy a FIXED disaggregated
# fleet under ONE router policy ("arm"), replay the agentic trace with aiperf, then
# tear it down. Arms differ ONLY in the Frontend router env; each arm runs on its own
# freshly-created fleet so a warmed prefix from one policy cannot leak into the next
# (cache-hit isolation — see benchmarks/router/README.md).
#
#   arm = kv | kv-predict | session | round-robin | load-aware
#
# The benchmark fleet has NO planner and multiple prefill/decode replicas, so routing
# quality — not autoscaling — is the only moving part, and the router has a real choice
# of workers to make. The mocker keeps prefix caching ON and a FINITE --speedup-ratio so
# a cache hit still produces a real (compressed) TTFT delta.
#
# chmod +x scripts/bench.sh
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

require_cmd kubectl envsubst yq

ACTION="${1:-}"
ARM="${2:-${BENCH_ARM:-kv}}"

BENCH_ROUTER_DIR="${BENCH_DIR}/router"
FLEET_BASE="${BENCH_ROUTER_DIR}/fleet-base.yaml"
AIPERF_JOB="${BENCH_ROUTER_DIR}/aiperf-job.yaml"

# Sweep knobs (override via env). The kv arm reads the credit; session/predict read TTLs.
# See ADR 0010 for what each flag does.
BENCH_OVERLAP_CREDIT="${BENCH_OVERLAP_CREDIT:-1.0}"
BENCH_SESSION_TTL="${BENCH_SESSION_TTL:-600}"
BENCH_PREDICTED_TTL="${BENCH_PREDICTED_TTL:-5}"
# kv-overlap-score-credit values the sweep walks for the kv arm.
BENCH_CREDITS="${BENCH_CREDITS:-1 2 4}"

bench_arm_dgd() { printf 'mocker-bench-%s' "$1"; }
bench_frontend_url() {
  printf 'http://%s-frontend.%s.svc.cluster.local:8000' "$(bench_arm_dgd "$1")" "$NS_DYNAMO"
}

# router_env_json <arm> — the Frontend router env entries this arm ADDS, as a JSON array
# yq appends to the Frontend container's env. Only the flags an arm needs are added (no
# disable sentinels), so each arm's config stays clean. The README's arm table mirrors this.
# VERIFY (live, against the pinned Dynamo release): the env var NAMES below, and that a
# shipped default (unset) disables session-affinity / predicted-ttl / load-aware.
router_env_json() {
  local arm="$1"
  local kv='{"name":"DYN_ROUTER_MODE","value":"kv"}'
  local rr='{"name":"DYN_ROUTER_MODE","value":"round-robin"}'
  local credit='{"name":"DYN_ROUTER_KV_OVERLAP_SCORE_CREDIT","value":"'"${BENCH_OVERLAP_CREDIT}"'"}'
  case "$arm" in
    kv)          printf '[%s,%s]' "$kv" "$credit" ;;
    kv-predict)  printf '[%s,%s,%s]' "$kv" "$credit" \
                   '{"name":"DYN_ROUTER_PREDICTED_TTL_SECS","value":"'"${BENCH_PREDICTED_TTL}"'"}' ;;
    session)     printf '[%s,%s,%s]' "$kv" "$credit" \
                   '{"name":"DYN_ROUTER_SESSION_AFFINITY_TTL_SECS","value":"'"${BENCH_SESSION_TTL}"'"}' ;;
    round-robin) printf '[%s]' "$rr" ;;
    load-aware)  printf '[%s,%s]' "$kv" '{"name":"DYN_ROUTER_LOAD_AWARE","value":"true"}' ;;
    *) die "unknown arm '$arm' (expected: kv|kv-predict|session|round-robin|load-aware)" ;;
  esac
}

fleet_up() {
  local arm="$1" env_json expr
  ensure_kubeconfig
  ensure_namespace "$NS_DYNAMO"
  [[ -f "$FLEET_BASE" ]] || die "fleet base manifest not found: ${FLEET_BASE}"
  env_json="$(router_env_json "$arm")"
  BENCH_ARM="$arm"
  export BENCH_ARM DYNAMO_VERSION
  # Append the arm's router env onto the Frontend container. VERIFY the yq path against a
  # rendered manifest before the first live run (v1beta1 spec.components[].podTemplate...).
  expr="(.spec.components[] | select(.name == \"Frontend\") | .podTemplate.spec.containers[] | select(.name == \"main\") | .env) += ${env_json}"
  step "Bench fleet up (arm=${arm}, dgd=$(bench_arm_dgd "$arm"), credit=${BENCH_OVERLAP_CREDIT})"
  render < "$FLEET_BASE" | yq "$expr" | kubectl apply -f -
  log "waiting for the benchmark fleet to become Ready..."
  kubectl -n "$NS_DYNAMO" wait --for=condition=Ready \
    dynamographdeployment "$(bench_arm_dgd "$arm")" --timeout=600s >/dev/null 2>&1 \
    || warn "DGD Ready not observed within timeout — check pod status"
  ok "arm '${arm}' fleet applied"
}

fleet_down() {
  local arm="$1"
  ensure_kubeconfig
  step "Bench fleet down (arm=${arm})"
  kubectl -n "$NS_DYNAMO" delete dynamographdeployment "$(bench_arm_dgd "$arm")" \
    --ignore-not-found --timeout=300s || true
  ok "arm '${arm}' fleet removed"
}

aiperf_run() {
  local arm="$1"
  ensure_kubeconfig
  ensure_namespace "$NS_LOAD"
  [[ -f "$AIPERF_JOB" ]] || die "aiperf job manifest not found: ${AIPERF_JOB}"
  BENCH_ARM="$arm"
  BENCH_FRONTEND_URL="$(bench_frontend_url "$arm")"
  export BENCH_ARM BENCH_FRONTEND_URL
  step "aiperf run (arm=${arm} -> ${BENCH_FRONTEND_URL})"
  render < "$AIPERF_JOB" | kubectl delete --ignore-not-found -f - >/dev/null 2>&1 || true
  render < "$AIPERF_JOB" | kubectl apply -f -
  ok "aiperf job started for arm '${arm}'"
  log "follow logs:  kubectl -n ${NS_LOAD} logs -f job/aiperf-bench-${arm}"
}

# sweep — the intended end-to-end orchestration: for each arm, stand up a cold fleet, run
# aiperf, collect results, tear down; sweeping BENCH_CREDITS for the kv arm.
# VERIFY (live): the block-until-complete + results-collection steps are marked TODO below.
# Run a single arm end-to-end (make bench-router-up/run/down ARM=...) before sweeping.
sweep() {
  local arm credit
  for credit in $BENCH_CREDITS; do
    BENCH_OVERLAP_CREDIT="$credit"
    export BENCH_OVERLAP_CREDIT
    fleet_up kv
    aiperf_run kv
    warn "TODO(live): wait for job/aiperf-bench-kv to Complete, then copy profile_export_aiperf.json to results/kv-credit-${credit}/"
    fleet_down kv
  done
  for arm in session round-robin load-aware; do
    fleet_up "$arm"
    aiperf_run "$arm"
    warn "TODO(live): wait for job/aiperf-bench-${arm} to Complete, then copy profile_export_aiperf.json to results/${arm}/"
    fleet_down "$arm"
  done
  log "compare with:  python3 ${BENCH_ROUTER_DIR}/analysis/compare.py results/"
}

case "${ACTION}" in
  up)    fleet_up "$ARM" ;;
  run)   aiperf_run "$ARM" ;;
  down)  fleet_down "$ARM" ;;
  sweep) sweep ;;
  *)     die "usage: bench.sh up|run|down|sweep [kv|kv-predict|session|round-robin|load-aware]" ;;
esac
