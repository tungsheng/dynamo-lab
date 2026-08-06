# Umbrella reorg: a kernel → capabilities → experiments/benchmarks layering

Reorganize the repo into a **3-layer model** so every experiment and benchmark is a **self-contained
unit** sitting on a shared, unchanged substrate:

```
infra/            # was terraform/         — kernel: VPC/EKS/Karpenter
platform/         # shared installs: etcd, nats, operator, observability-base, chaos-mesh, karpenter, grove
lib/              # was scripts/lib/        — shared shell + make includes
capabilities/     # reusable components experiments COMPOSE:
  fleet/  chaos/  load/  dashboards/
experiments/      # "inject a condition, observe" — recover(A) autoscale(B) spike(C) grove(G)
benchmarks/       # "sweep a matrix, rank by a metric" — router/
Makefile          # thin dispatcher → includes each unit's own *.mk
```

The reorg is a **goal**, but sequenced: it lands **after** the first benchmark (a second PR), so the
capability abstractions are validated against ≥2 real consumers instead of designed up front. Both
this ADR and ADR [0010](0010-router-benchmark-kv-vs-session.md) are written now; the reorg *code*
follows the benchmark.

## Why

Two concrete pains, both code-organization not infra: an **experiment is not a self-contained
unit** (experiment A is smeared across `chaos/`, `fleet/`, `load/`, `platform/observability/`,
`scripts/`, `Makefile`, `docs/adr/`), and the **repo root clutters** as experiments multiply —
invisible at A/B/C + Track G, biting by 5–8 units. The fix is to make `fleet`/`chaos`/`load`/
`dashboards` **reusable capabilities** and experiments/benchmarks **thin compositions** of them.

Sequencing behind the benchmark is not just caution, it is the *honest* order: today `fleet` and
`load` have one class of consumer (the experiments), so extracting them now would generalize from a
sample of one. **Building the benchmark first creates the second consumer** that justifies the
extraction. The substrate is deliberately untouched — one CPU-only cluster, one `make up`, one
`$0`-idle teardown (ADRs [0001](0001-eks-for-a-gpu-free-lab.md),
[0006](0006-s3-state-and-destroy-on-down.md)); "projects" means self-contained overlays, not
isolated stacks. Track G already proved a substantial capability can be added *without* a reorg, so
this pays down a maintainability north-star, it does not unblock the roadmap.

## Consequences

- **Shared kernel preserved:** every unit still shares the one cluster and lifecycle; no per-project
  clusters or state. The only sanctioned escape hatch is a real-GPU track (Track N), which gets its
  own node class, not this structure.
- **Two PRs, both ADRs up front.** The reorg PR **moves live-validated paths** (updating
  `fleet.sh`/`chaos.sh`/`load.sh`/`Makefile`/embedded manifest paths), so it requires a **full live
  re-validation** of A/B/C + Track G on EKS — the same discipline the v1beta1 and Track G migrations
  used. The moves themselves are mechanical.
- **Capability extraction is gated by the ≥2-consumer rule**; **experiment units stay thin** (a
  README + make-include + parameter values), resisting the pull to fatten them. If `capabilities/
  fleet` cannot cleanly serve both an existing experiment and the benchmark, the seam is wrong and
  we stop and rethink.
- **Vocabulary additions** — kernel / capability, and *experiment* (observe) vs *benchmark*
  (measure+rank) — are reconciled in `CONTEXT.md` alongside the existing fleet / experiment / Track
  terms.
- **Rejected:** reorg-first / big-bang (extracts abstractions from a sample of one and churns a
  live-validated `main` before any research payoff); independently deployable per-project stacks
  (multiplies clusters or re-implements overlay multiplexing, killing the `$0`-idle bet); folding
  benchmarks into `experiments/` (different machinery — a sweep-and-rank harness vs
  inject-and-observe — so one tree muddies both).
