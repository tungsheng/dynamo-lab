# A GPU-free router benchmark: KV-aware vs session-affinity routing on agentic traces

Add a new **`benchmarks/`** tree whose first inhabitant, **`benchmarks/router/`**, measures where
Dynamo's **KV-aware router** underperforms **session (sticky) routing** on agentic — multi-turn,
shared-prefix — workloads, and by how much raising the KV-overlap cost weight closes the gap. It
runs **GPU-free on the mocker**, reuses Dynamo's upstream `benchmarks/router/` harness (aiperf +
the Mooncake FAST'25 toolagent trace), and treats the **routing policy as a pluggable "policy under
test" axis** so a custom scorer can drop in later. This is a *benchmark* (sweep a config matrix,
rank by a metric), distinct from the A/B/C *experiments* (inject a condition, observe behaviour).

## Why

For agentic serving a prefill cache-miss is very costly, and the hypothesis from the Dynamo team is
that **session routing is close to optimal for prefill** — so the KV router should match it once its
cost function weights KV overlap heavily enough. That is a routing-*decision* question, and the
mocker is the right substrate for it: it runs Dynamo's **real** router code path while simulating
compute, and — verified against primary sources — it simulates **prefix-cache reuse** on the same
logical block manager the runtime uses (`ActiveHit`/`InactiveHit`/`NewStore`, publishing the KV
`Stored` events the router consumes), so a cache hit shrinks effective prefill ISL and produces a
**real TTFT delta**. The routing decisions are real even though the GPUs are not — the same
GPU-free, `$0`-idle bet as the rest of the lab (ADR [0001](0001-eks-for-a-gpu-free-lab.md)).

The whole comparison is answerable **today** with shipped flags (no fork, no custom binary):

- **Arm A — KV-aware.** `DYN_ROUTER_MODE=kv`, sweeping `--router-kv-overlap-score-credit`
  (`DYN_ROUTER_KV_OVERLAP_SCORE_CREDIT`, default `1.0`) ∈ {1, 2, 4}, optionally with
  `--router-predicted-ttl-secs 5` to pin sibling requests that share a system prompt before any KV
  event has fired (the agentic batch-of-siblings race).
- **Arm B — session/sticky.** `--router-session-affinity-ttl-secs` (orthogonal to `--router-mode`).
- **Arm C — cache-blind floors.** `--router-mode round-robin` and `--load-aware` (overlap credit 0,
  events off).

Reusing the upstream harness (rather than writing our own trace replay) keeps results **directly
comparable to Dynamo's own KV-vs-round-robin A/B recipe**, and the only thing that recipe lacks is
the session arm — which is exactly this benchmark's contribution and the surface for an upstream PR.
ADR [0005](0005-k6-load-generator.md) already reserved AIPerf as the lab's "realistic benchmark
mode"; this is that mode. (The intuitive-sounding `--kv-overlap-score-weight` is **deprecated** and
now aliases `prefill_load_scale`, a different lever — the live knob is `-credit`.)

## Consequences

- **Relative, not absolute.** The mocker interpolates whatever profiling data it is given, so the
  benchmark yields **policy orderings and gap-closing curves**, not a specific GPU's absolute TTFT.
  Reproducing InferenceX-style numbers on real large models (Kimi-K3/DSv4 on B200) needs GPUs +
  srt-slurm/Slurm — a separate effort, Track-N-like, deliberately out of scope here.
- **No scalar cache-hit gauge** is exposed by the mocker; hit-rate is **derived from TTFT
  distributions** (and KV-event/overlap signals), documented as a proxy.
- **Cold-start isolation is a validity requirement:** each arm/point runs on a fresh
  namespace/fleet so a warmed prefix from one policy cannot leak into the next.
- **Scorer-ready, not scorer-blocked.** Issue #11875 (native composable `WorkerScorer`/`Picker`) is
  a **draft DEP, ~1 of 5 steps merged, Rust-only/compile-time** — a custom policy means building a
  router/EPP binary. The harness keeps policy as a swappable input so that image is a future *arm*,
  never a prerequisite.
- New external dependency on upstream **aiperf** + the **Mooncake toolagent trace**, pinned; the
  Mooncake trace is representative enough to start and can be swapped for a coding-agent trace later.
- **Rejected:** reimplementing trace replay in k6 (loses aiperf's serving-metric rigor and
  cross-comparability; k6 single-turn prompts carry no shared-prefix signal); blocking v1 on #11875
  (not landed, and answers a *capability* question, not the *research* one); a real-GPU replay in
  this lab (breaks the `$0`-idle / GPU-free invariant).
