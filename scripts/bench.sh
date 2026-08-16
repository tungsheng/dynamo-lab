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

require_cmd kubectl envsubst awk

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

# bench_env_entry <name> <value> — one YAML env entry indented to the Frontend env sequence
# in fleet-base.yaml. The 16/18-space indent MUST match that file's env list (kept in lockstep
# with the __BENCH_ROUTER_ENV__ marker there).
bench_env_entry() { printf '                - name: %s\n                  value: "%s"\n' "$1" "$2"; }

# router_env_yaml <arm> — the Frontend router env this arm sets, as a YAML block that replaces
# the __BENCH_ROUTER_ENV__ marker in fleet-base.yaml. Only the flags an arm needs are emitted
# (no disable sentinels), so each arm's config stays clean — in particular the kv arm carries NO
# session-affinity env, which is what makes the kv-vs-session comparison honest. The README arm
# table mirrors this. Env var names verified against Dynamo 1.3.1 (router_args.py / kv_router_args.py)
# and exercised live 2026-08-11 (each arm's policy landed on the Frontend; session affinity binds only
# with the x-dynamo-session-id header — see aiperf-job.yaml).
router_env_yaml() {
  local arm="$1"
  case "$arm" in
    kv)
      bench_env_entry DYN_ROUTER_MODE kv
      bench_env_entry DYN_ROUTER_KV_OVERLAP_SCORE_CREDIT "$BENCH_OVERLAP_CREDIT" ;;
    kv-predict)
      bench_env_entry DYN_ROUTER_MODE kv
      bench_env_entry DYN_ROUTER_KV_OVERLAP_SCORE_CREDIT "$BENCH_OVERLAP_CREDIT"
      bench_env_entry DYN_ROUTER_PREDICTED_TTL_SECS "$BENCH_PREDICTED_TTL" ;;
    session)
      bench_env_entry DYN_ROUTER_MODE kv
      bench_env_entry DYN_ROUTER_KV_OVERLAP_SCORE_CREDIT "$BENCH_OVERLAP_CREDIT"
      bench_env_entry DYN_ROUTER_SESSION_AFFINITY_TTL_SECS "$BENCH_SESSION_TTL" ;;
    round-robin)
      bench_env_entry DYN_ROUTER_MODE round-robin ;;
    load-aware)
      bench_env_entry DYN_ROUTER_MODE kv
      bench_env_entry DYN_ROUTER_LOAD_AWARE true ;;
    *) die "unknown arm '$arm' (expected: kv|kv-predict|session|round-robin|load-aware)" ;;
  esac
}

# inject_router_env <arm> — filter stdin, replacing the __BENCH_ROUTER_ENV__ marker line with the
# arm's router env block. Passed via the environment (not awk -v) so embedded newlines survive.
inject_router_env() {
  BENCH_ROUTER_ENV="$(router_env_yaml "$1")" \
    awk '/__BENCH_ROUTER_ENV__/ { print ENVIRON["BENCH_ROUTER_ENV"]; next } { print }'
}

fleet_up() {
  local arm="$1" base rendered markers
  ensure_kubeconfig
  ensure_namespace "$NS_DYNAMO"
  [[ -f "$FLEET_BASE" ]] || die "fleet base manifest not found: ${FLEET_BASE}"
  BENCH_ARM="$arm"
  export BENCH_ARM DYNAMO_VERSION
  step "Bench fleet up (arm=${arm}, dgd=$(bench_arm_dgd "$arm"), credit=${BENCH_OVERLAP_CREDIT})"
  # Render the ARM/version tokens, then splice the arm's router policy into the marker line. The
  # marker MUST appear exactly once: 0 means it was lost (Frontend would silently fall back to the
  # default router mode); >1 means the token leaked into prose and the block would land in the
  # wrong place (invalid YAML). Fail loud on either rather than apply something malformed.
  base="$(render < "$FLEET_BASE")"
  markers="$(grep -c '__BENCH_ROUTER_ENV__' <<<"$base" || true)"
  [[ "$markers" == "1" ]] \
    || die "expected exactly one __BENCH_ROUTER_ENV__ marker in ${FLEET_BASE}, found ${markers}"
  rendered="$(inject_router_env "$arm" <<<"$base")"
  printf '%s\n' "$rendered" | kubectl apply -f -
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
  # Wait for the pods to actually clear before returning, so a follow-up `up` of the SAME name does
  # not race the operator's teardown (live 2026-08-06: rapid same-name delete+recreate left the new
  # DGD Ready=False with 0 pods). Prefer a DISTINCT arm/name per run for a clean cold fleet.
  kubectl -n "$NS_DYNAMO" wait --for=delete pod -l "dynamo-lab/arm=${arm}" --timeout=180s \
    >/dev/null 2>&1 || true
  ok "arm '${arm}' fleet removed"
}

aiperf_run() {
  local arm="$1"
  ensure_kubeconfig
  ensure_namespace "$NS_LOAD"
  [[ -f "$AIPERF_JOB" ]] || die "aiperf job manifest not found: ${AIPERF_JOB}"
  # Publish the session-trace generator so the Job (TRACE_MODE=session) can mount + run it.
  kubectl create configmap bench-router-gen -n "$NS_LOAD" \
    --from-file=make_session_trace.py="${BENCH_ROUTER_DIR}/make_session_trace.py" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  BENCH_ARM="$arm"
  BENCH_FRONTEND_URL="$(bench_frontend_url "$arm")"
  export BENCH_ARM BENCH_FRONTEND_URL
  step "aiperf run (arm=${arm} -> ${BENCH_FRONTEND_URL})"
  render < "$AIPERF_JOB" | kubectl delete --ignore-not-found -f - >/dev/null 2>&1 || true
  render < "$AIPERF_JOB" | kubectl apply -f -
  ok "aiperf job started for arm '${arm}'"
  log "follow logs:  kubectl -n ${NS_LOAD} logs -f job/aiperf-bench-${arm}"
}

# wait_job <arm> — block until the arm's aiperf Job reports Complete or Failed (bounded).
wait_job() {
  local arm="$1" t
  for _ in $(seq 1 200); do
    t="$(kubectl get job "aiperf-bench-${arm}" -n "$NS_LOAD" -o jsonpath='{.status.conditions[*].type}' 2>/dev/null)"
    case "$t" in
      *Complete*) ok "aiperf-bench-${arm} complete"; return 0 ;;
      *Failed*)   warn "aiperf-bench-${arm} failed"; return 1 ;;
    esac
    sleep 5
  done
  warn "aiperf-bench-${arm} did not finish within timeout"; return 1
}

# collect_arm <label> <arm> — pull the arm's aiperf export from the completed Job pod logs into
# results/<label>/. The export prints between the AIPERF-JSON markers; the pod is gone after ttl (so
# kubectl cp is out) and `kubectl logs | tail` truncates the JSON — take the FULL logs and slice.
collect_arm() {
  local label="$1" arm="$2" pod
  pod="$(kubectl get pods -n "$NS_LOAD" -l "dynamo-lab/arm=${arm}" -o name | head -1)"
  [[ -n "$pod" ]] || { warn "no aiperf pod for arm ${arm}"; return 1; }
  mkdir -p "results/${label}"
  kubectl logs -n "$NS_LOAD" "$pod" > "results/${label}/run.log" 2>&1
  python3 -c 'import re,json,sys; log=open(sys.argv[1]).read(); m=re.search(r"===AIPERF-JSON-BEGIN===\s*(.*?)===AIPERF-JSON-END===",log,re.S); open(sys.argv[2],"w").write(json.dumps(json.loads(m.group(1).strip()),indent=2)) if m else sys.exit("no aiperf export markers")' \
    "results/${label}/run.log" "results/${label}/profile_export_aiperf.json" \
    && ok "collected results/${label}/profile_export_aiperf.json" || warn "no export extracted for ${label}"
}

# sweep — stand up a cold fleet per arm, run aiperf (TRACE_MODE=session by default so every arm
# replays the SAME session-grouped workload), collect, tear down. Sweeps BENCH_CREDITS on the kv
# arm, then kv-predict / session / cache-blind floors. NOTE (live 2026-08-06): the kv credit loop
# reuses the same DGD name, which can hit an operator delete-recreate race (new DGD Ready=False, 0
# pods) even with the fleet_down wait; for a clean credit sweep run on a FRESH cluster or give each
# run a distinct name.
sweep() {
  local arm credit
  for credit in $BENCH_CREDITS; do
    BENCH_OVERLAP_CREDIT="$credit"; export BENCH_OVERLAP_CREDIT
    fleet_up kv
    aiperf_run kv
    wait_job kv && collect_arm "kv-credit-${credit}" kv
    fleet_down kv
  done
  for arm in kv-predict session round-robin load-aware; do
    fleet_up "$arm"
    aiperf_run "$arm"
    wait_job "$arm" && collect_arm "$arm" "$arm"
    fleet_down "$arm"
  done
  log "compare:  python3 ${BENCH_ROUTER_DIR}/analysis/compare.py results/"
}

case "${ACTION}" in
  up)    fleet_up "$ARM" ;;
  run)   aiperf_run "$ARM" ;;
  down)  fleet_down "$ARM" ;;
  sweep) sweep ;;
  *)     die "usage: bench.sh up|run|down|sweep [kv|kv-predict|session|round-robin|load-aware]" ;;
esac
