# Track G: observe Grove gang-scheduling GPU-free; defer the NIXL data plane

Add an **optional, additive track** that exercises [Grove](https://github.com/NVIDIA/grove)
— Dynamo's Kubernetes gang-scheduling / multi-component orchestration layer — with the
existing mocker fleet, driven by a gang scheduler (KAI-Scheduler). It is gated behind its own
switch and does **not** change the default `make up`/`down` path or the headline experiments
(A chaos, B autoscale, C spike). The GPU-bound NIXL KV-transfer data plane is **out of scope**
here (see Consequences).

## Why

Grove groups a fleet's components (frontend / prefill / decode / router) into a gang that
schedules **all-or-nothing**, scales the prefill+decode unit as one via a scaling group, and
places pods topology-aware with custom startup ordering. Almost all of that is *control-plane*
behaviour: the mocker already runs Dynamo's real operator/planner code paths while simulating
compute, so gang formation, gang-blocked `Pending`, multi-level autoscaling, and placement are
observable **without GPUs** — the same GPU-free, `$0`-idle bet as the rest of the lab (ADR
[0001](0001-eks-for-a-gpu-free-lab.md)). It also composes with what we already built: chaos can
kill a gang member and we watch the gang reconcile, and a spike drives Karpenter (ADR
[0008](0008-karpenter-node-autoscaling.md)) into gang-aware node pressure.

Splitting this out as "Track G" keeps the pre-planned roadmap intact — it is a new platform
component plus a fleet overlay, never a reorder of the existing milestones.

## Consequences

- New platform dependency (Grove operator + KAI-Scheduler) and new upstream API surface
  (`PodClique` / `PodCliqueScalingGroup` / `PodGangSet` — exact group/version pinned + `#
  VERIFY:`'d against a Grove release, as every upstream fact in this repo is).
- The mocker validates *scheduling behaviour*, not the physics: real topology-aware placement
  only fully bites on real multi-node GPU topology, so placement is observed against
  synthetic topology labels + resource pressure. Called out as a known limitation.
- **Track N (NIXL) deferred.** NIXL only moves real KV tensors, which the mocker never
  produces, so a meaningful NIXL test needs real GPUs (and RDMA/EFA for its transport
  backend) — a real-cost experiment that breaks the `$0`-idle bet. Documented as the explicit
  non-goal of this track; if pursued it gets its own ADR and node class, not this one.
- Rejected: **fold Grove into the default `make up`** (would disrupt the roadmap and make the
  baseline heavier for the A/B/C experiments); **Kueue instead of KAI-Scheduler** (KAI is the
  Dynamo/Grove-aligned gang scheduler — revisit only if Grove drops it).
