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

## Live validation (2026-08-11) — follow-up implemented, STILL no signal

The three levers all landed and ran clean on a real cluster (session workload with **191 tracked
sessions**, block-size 16/16 confirmed on the pods, kv-predict + sticky arms live), yet the routing
policy still made no TTFT difference:

| arm | TTFT avg | TTFT p99 | E2EL |
|---|---|---|---|
| round-robin (cache-blind) | **523 ms** | 841 | 655 |
| kv (credit=1) | 530 ms | 857 | 685 |
| load-aware | 564 ms | 1031 | 673 |
| session (sticky) | 565 ms | 920 | 682 |
| kv-predict | 567 ms | 917 | 688 |

All within 8%, cache-blind round-robin lowest — **sticky does not beat cache-blind**. (Also fixed a
live bug: aiperf's `--request-count` defaults to ~10, *not* the dataset size — restored it to the
trace's row count.)

- `--router-predicted-ttl-secs` (kv-predict) — ✅ implemented + validated; no effect here.
- Block-size alignment (16/16) — ✅ implemented + confirmed on the pods; no effect here.
- Session workload (`make_session_trace.py`, `TRACE_MODE=session`) — ✅ implemented; aiperf tracked
  191 sessions, so the sticky arm ran on a real multi-turn workload.

**The bottleneck is deeper than routing config.** Two candidate root causes remain, both needing
router/mocker **log** inspection (not config) to distinguish:
- **(A) session-affinity may not be pinning** — aiperf may not send a session id the router keys on;
  if sticky isn't binding sessions to workers it can't earn the locality that would beat cache-blind.
- **(B) the mocker may not discount cached tokens from TTFT** at `--speedup-ratio 10`, so even
  perfect routing shows no TTFT gain.

→ **Root cause resolved below.**

## Root cause (2026-08-11, Dynamo 1.3.1) — RESOLVED

The root-cause session settled it: **(A) confirmed and fixed, (B) ruled out — but sticky still loses,
for a deeper reason.**

- **(A) the session id never reached the router.** Dynamo binds affinity only on the HTTP header
  `x-dynamo-session-id`; aiperf sends `X-Correlation-ID` by default, which the router ignores. Fix:
  `AIPERF_HTTP_X_DYNAMO_SESSION_ID_FROM_CORRELATION_ID=true` (aiperf ≥0.12.0). After the fix the router
  computes non-zero overlap (`router_kv_hit_rate` ~0.2) and the mockers publish KV events — the
  mechanism works.
- **(B) ruled out:** the mocker charges prefill on uncached tokens only (`predict_prefill_time`
  returns 0 for a fully-cached prompt).

**Result with the fix (session header on the wire):**

| arm | TTFT avg |
|---|---|
| round-robin (cache-blind) | **535 ms** ← best |
| kv | 544 ms |
| kv-predict | 549 ms |
| load-aware | 561 ms |
| session (sticky) | **573 ms** ← worst |

**Sticky is the _worst_ arm.** The achieved overlap is only ~20%, and that small cache benefit is
outweighed by sticky's load-balancing cost (pinning a session concentrates load → queueing) on a
cheap-prefill mocker (speedup 10, 4 workers, concurrency 32).

**Conclusion — a _regime_ gap, not a bug.** On the GPU-free mocker at this scale cache locality is too
cheap for sticky to win; "sticky ≈ optimal for prefill" needs an expensive-prefill regime (large
models / big prefixes / real KV-transfer) — i.e. **Stage 3 (real GPUs)**. The instrument, router, and
affinity all work; the mocker sits on the wrong side of the cache-benefit-vs-load-balance crossover.
To push it toward the crossover: many more turns/session + larger `--system-blocks` (raise realized
overlap well above 20%), and confirm per-session pinning via `router_kv_hit_rate` per worker.
(`fleet_down` waits for pod deletion; prefer a distinct DGD name per credit run — the same-name race.)

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

The policy is a **pluggable axis**, so Dynamo's native composable Selector (#11875) becomes a future
arm: a custom-scorer image slots in beside the flag-based arms with the same trace and metrics.
**Status (2026-08-14):** #11875 is **merged + closed-completed on Dynamo `main`** — `WorkerScorer` /
`WorkerFilter` / `WorkerPicker` traits + a `SelectionServiceBuilder` factory + example policy crates
(`examples/router/custom-policy-example/`, feature `standalone-selection`). It is **not in a stable
release yet**, and `main` is release-gated (see Upstream watch), so the custom-scorer arm lands at the
next stable release or via a source-build spike. Never a prerequisite for the flag-based arms here.

## Upstream watch (Dynamo `main`, as of 2026-08-14)

Audited `v1.3.1...main` — **nothing forces a change** to this 1.3.1-pinned lab (mocker CLI, all 7
router env vars, session-affinity keying, DGD spec, helm keys, aiperf all intact). Two `main`-only
items are worth adopting when they release (or in a deliberate source build):

- **#11875 — composable Selector plug-in** (above): makes the custom-scorer arm real.
- **#12711 — a direct measured cache-hit signal**: the mocker now emits post-eviction `cached_tokens`
  in the first chunk's `completion_usage`, so the frontend cache-hit metric reflects *actual* hits.
  This would replace the TTFT-derived hit-rate (the [ADR 0010](../../docs/adr/0010-router-benchmark-kv-vs-session.md)
  "no scalar cache-hit gauge" limitation) — exactly what read 0 in the root-cause session.
- **CRD storage flipped v1alpha1 → v1beta1** on `main` (#11904) — *aligns* with this lab's v1beta1
  manifests; no action.
- **`main` is release-gated:** NGC publishes `dynamo-planner` + `dynamo-platform` only on release
  tags (nightlies exclude both). Reaching `main` = build from source or repackage the `ai-dynamo`
  nightly wheel into a CPU image — a spike, not a pin bump. (aiperf's native `x-dynamo-session-id`
  header, #1151, is already what this lab uses via the `AIPERF_HTTP_*` env.)

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
