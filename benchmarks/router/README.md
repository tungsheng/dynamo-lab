# benchmarks/router — KV-aware vs session routing on agentic traces

The first inhabitant of the `benchmarks/` tree (ADR
[0010](../../docs/adr/0010-router-benchmark-kv-vs-session.md)). It measures **where Dynamo's
KV-aware router underperforms session (sticky) routing** on agentic — multi-turn, shared-prefix —
traffic, and **how much raising the KV-overlap cost weight closes the gap**. GPU-free on the
**mocker**; the routing decisions are the real Dynamo code path.

> **Validated live on EKS 2026-08-06** — the harness runs end-to-end (fleet Ready → router-env
> injection → aiperf trace replay → export collected). The first run's key result (no routing signal
> yet) and the follow-ups to make it discriminating are in **[Live findings](#live-findings-first-run-2026-08-06)**
> below. It uses Dynamo's upstream aiperf form (`aiperf==0.10.0`, `aiperf profile
> --custom-dataset-type mooncake_trace`) against the Mooncake FAST'25 toolagent trace; the **session
> arm** (this benchmark's intended contribution) is blocked on a session-grouped trace — see below.

## Live findings (first run, 2026-08-06)

**The harness works end-to-end but is not yet *discriminating*** — on the stock trace/config the
routing policy made no measurable TTFT difference.

- **Pipeline validated.** `make bench-router-up ARM=kv` → DGD Ready; the awk-injected router env
  lands in the Frontend (`DYN_ROUTER_MODE=kv`, `DYN_ROUTER_KV_OVERLAP_SCORE_CREDIT`); the KV router
  activates; the aiperf Job replays the trace and emits `profile_export_aiperf.json`.
- **aiperf pinned:** `aiperf==0.10.0`, `aiperf profile ... --custom-dataset-type mooncake_trace` on a
  `python:3.12-slim` + pip base. aiperf materializes the whole trace before `--request-count`, so the
  full 23,608-row trace **OOMs** — the Job subsets to `TRACE_ROWS`. Export metrics are top-level keys
  (`time_to_first_token`, `inter_token_latency`, `request_latency`; **no** `time_per_output_token`).
- **No-signal result** (2000 reqs, concurrency 32, cold fleet per arm):

  | arm | TTFT avg | TTFT p99 | E2EL avg | req/s |
  |---|---|---|---|---|
  | kv-credit-1 | 312 ms | 674 ms | 441 ms | 5.9 |
  | round-robin | 296 ms | 687 ms | 424 ms | 5.9 |
  | load-aware  | 304 ms | 686 ms | 430 ms | 5.9 |

  Duration and throughput were identical too, and cache-blind **round-robin was marginally lowest** —
  the router is not exploiting prefix locality on this config.
- **kv-credit-4 blocked** by an operator delete-recreate race (a rapidly recreated same-name DGD came
  up `Ready=False` with 0 pods; distinct-named arms were unaffected).

**To make it discriminating — status after the follow-up (`feat/router-benchmark-followup`):**
1. **`--router-predicted-ttl-secs`** — ✅ *implemented*: the `kv-predict` arm is in the sweep. At
   concurrency the batch-of-siblings race makes plain kv scatter co-arriving shared-prefix requests
   like round-robin; predict-on-route pins them. **Pending live validation.**
2. **Block-size alignment** — ✅ *implemented*: mocker `--block-size 16` + Frontend
   `DYN_KV_CACHE_BLOCK_SIZE=16` in `fleet-base.yaml`, so trace prefixes map to credited overlap.
   **Pending live validation.**
3. **Session workload** — ✅ *implemented*: `make_session_trace.py` generates a session-grouped
   multi-turn trace with a growing per-session prefix (`TRACE_MODE=session`, the default), so the
   **session-affinity arm is now meaningful** — the kv-vs-sticky comparison can actually run.
4. **Mocker cache→TTFT sensitivity** — ⬜ open: confirm a prefix hit lowers simulated TTFT at
   `--speedup-ratio 10` (needs the live run; try a lower ratio / different profile data if flat).
5. **Sweep methodology** — `fleet_down` now waits for pod deletion; still prefer a distinct DGD name
   per credit run (the same-name recreate race).

The next live run replays the session trace across all arms and reads off **where kv TTFT > session
TTFT** (the router-underperforms-sticky cases) and whether `overlap-score-credit` + predict-on-route
close the gap.

## The arms

Each arm is the same fixed fleet with a different Frontend router policy. `scripts/bench.sh`
splices the arm's router env into the Frontend (replacing the `__BENCH_ROUTER_ENV__` marker in
`fleet-base.yaml`); the table below mirrors `router_env_yaml()` there.

| Arm | Router env it sets | Question |
|-----|--------------------|----------|
| `kv` | `DYN_ROUTER_MODE=kv`, `DYN_ROUTER_KV_OVERLAP_SCORE_CREDIT=<sweep>` | Does KV routing match session as overlap weight rises? |
| `kv-predict` | `kv` + `DYN_ROUTER_PREDICTED_TTL_SECS=5` | Does predict-on-route fix the batch-of-siblings race (many requests sharing a system prompt before any KV event fires)? |
| `session` | `kv` + `DYN_ROUTER_SESSION_AFFINITY_TTL_SECS=<ttl>` | The near-optimal-for-prefill baseline. |
| `round-robin` | `DYN_ROUTER_MODE=round-robin` | Cache-blind floor. |
| `load-aware` | `kv` + `DYN_ROUTER_LOAD_AWARE=true` | Cache-blind floor (overlap credit 0, events off). |

`--router-kv-overlap-score-credit` (default `1.0`, may exceed 1.0) is **the** knob for "put more
weight on KV overlap." Note the intuitive-sounding `--kv-overlap-score-weight` is **deprecated** and
aliases `prefill_load_scale` — a different lever. See ADR 0010 for the full cost function.

## Method — why it's built this way

- **Fixed fleet, no planner** ([fleet-base.yaml](fleet-base.yaml)): replicas are pinned and there
  is no autoscaler, so **routing quality is the only moving part**. A planner scaling pods mid-run
  would confound the TTFT comparison.
- **prefill/decode replicas = 4**: the router needs several workers to choose among, or "which
  worker" is not a real decision and every policy looks the same.
- **Prefix caching ON + finite `--speedup-ratio`**: a cache hit shrinks effective prefill ISL and
  still yields a real, wall-clock-compressed TTFT delta. `--speedup-ratio 0` (no delays) would erase
  the signal — do not use it here.
- **Cold-start isolation**: each arm (and each credit point) runs on a **freshly created fleet**
  (`mocker-bench-<arm>`), so a warmed prefix from one policy cannot leak into the next.
- **Metrics**: aiperf **TTFT / TPOT / ITL / E2EL**. There is no scalar cache-hit-rate gauge, so
  **hit-rate is read from TTFT** (a hit lowers TTFT). Relative orderings only — not B200 absolutes.

## Run it

```bash
# one arm, end to end (default ARM=kv):
make bench-router-up   ARM=kv BENCH_OVERLAP_CREDIT=2
make bench-router-run  ARM=kv
make bench-router-down  ARM=kv

# arms: kv | kv-predict | session | round-robin | load-aware
# the whole matrix (cold fleet -> aiperf -> teardown per arm; sweeps BENCH_CREDITS for kv):
scripts/bench.sh sweep

# then compare the collected aiperf exports:
python3 benchmarks/router/analysis/compare.py results/
```

Sweep knobs (env): `BENCH_OVERLAP_CREDIT` (kv), `BENCH_SESSION_TTL` (session), `BENCH_PREDICTED_TTL`
(kv-predict), `BENCH_CREDITS` (credit values). Workload: `TRACE_MODE=session` (default; a generated
multi-turn trace) or `toolagent`; `SESSIONS` / `TURNS` size the session trace.

## Scorer-ready (future arm)

The policy is a **pluggable axis**, so Dynamo issue #11875 (native composable
`WorkerScorer`/`Picker`) becomes a future arm: a custom-scorer image slots in beside the flag-based
arms with the same trace and metrics. #11875 is a **draft DEP (Rust-only, ~1/5 steps merged)**, so
it is a drop-in later — never a prerequisite for the flag-based research answer here.

## Layout

| Path | What |
|------|------|
| [fleet-base.yaml](fleet-base.yaml) | the fixed disagg benchmark fleet (no planner, 4+4 workers, block-size 16) |
| [make_session_trace.py](make_session_trace.py) | generates the session-grouped trace (`TRACE_MODE=session`) |
| [aiperf-job.yaml](aiperf-job.yaml) | in-cluster aiperf runner (session or toolagent trace replay) |
| [analysis/compare.py](analysis/compare.py) | tabulate aiperf exports across arms |
| `../../scripts/bench.sh` | orchestration: `up`/`run`/`down`/`sweep`, per-arm router env |

See ADR [0011](../../docs/adr/0011-umbrella-reorg-capabilities-experiments-benchmarks.md) for how
this `benchmarks/` tree fits the planned kernel → capabilities → experiments/benchmarks layering.
