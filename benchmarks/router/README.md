# benchmarks/router — KV-aware vs session routing on agentic traces

The first inhabitant of the `benchmarks/` tree (ADR
[0010](../../docs/adr/0010-router-benchmark-kv-vs-session.md)). It measures **where Dynamo's
KV-aware router underperforms session (sticky) routing** on agentic — multi-turn, shared-prefix —
traffic, and **how much raising the KV-overlap cost weight closes the gap**. GPU-free on the
**mocker**; the routing decisions are the real Dynamo code path.

> This is a **scaffold**. The structure, arms, and wiring are in place; items marked `VERIFY`
> (the aiperf invocation, trace fetch, runner image, and results collection) are pinned
> on the first live run. It reuses Dynamo's upstream `benchmarks/router/` harness (aiperf +
> `agent_benchmark.py` + the Mooncake FAST'25 toolagent trace) — the one thing that harness lacks
> is the **session arm**, which is this benchmark's contribution.

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
(kv-predict), `BENCH_CREDITS` (the credit values `sweep` walks for kv).

## Scorer-ready (future arm)

The policy is a **pluggable axis**, so Dynamo issue #11875 (native composable
`WorkerScorer`/`Picker`) becomes a future arm: a custom-scorer image slots in beside the flag-based
arms with the same trace and metrics. #11875 is a **draft DEP (Rust-only, ~1/5 steps merged)**, so
it is a drop-in later — never a prerequisite for the flag-based research answer here.

## Layout

| Path | What |
|------|------|
| [fleet-base.yaml](fleet-base.yaml) | the fixed disagg benchmark fleet (planner removed, replicas raised) |
| [aiperf-job.yaml](aiperf-job.yaml) | in-cluster aiperf runner (agentic trace replay) — `VERIFY`-marked |
| [analysis/compare.py](analysis/compare.py) | tabulate aiperf exports across arms |
| `../../scripts/bench.sh` | orchestration: `up`/`run`/`down`/`sweep`, per-arm router env |

See ADR [0011](../../docs/adr/0011-umbrella-reorg-capabilities-experiments-benchmarks.md) for how
this `benchmarks/` tree fits the planned kernel → capabilities → experiments/benchmarks layering.
