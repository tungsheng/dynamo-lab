# Dynamo Lab

A GPU-free experimentation lab for observing how an NVIDIA Dynamo inference **fleet**
behaves under failure, autoscaling, and traffic spikes. It runs on Amazon EKS; workers
are simulated (the Dynamo *mocker*) so no GPUs are involved. The point of the lab is to
*watch* the system: recover from injected failures, autoscale under load, and hold up
under traffic spikes.

## Language

**Fleet**:
The set of Dynamo components serving inference as one unit — frontend, KV-aware router,
worker pool(s), and planner — declared as a single `DynamoGraphDeployment` and reconciled
by the Dynamo operator.
_Avoid_: cluster (reserved for the EKS cluster), deployment, stack.

**Mocker worker** (or **Mocker**):
A GPU-free simulated inference worker. It runs Dynamo's real router/planner code path
while *simulating* KV-cache management and prefill/decode timing instead of executing a
model. The only worker engine this lab uses.
_Avoid_: mock, stub, fake worker, simulator.

**Coordination plane**:
The two shared-state services the fleet depends on — **etcd** (service discovery via
leases) and **NATS** (the KV event plane). Run highly-available here because they are the
fleet's single points of failure and sit on the KV-aware routing critical path.
_Avoid_: control plane (reserved for the Kubernetes/EKS control plane), infra, backend.

**Aggregated** / **Disaggregated**:
The two fleet topologies. *Aggregated* — each worker does both prefill and decode (one
pool). *Disaggregated* — separate prefill and decode worker pools that exchange KV cache.
The lab brings up on aggregated and runs its headline experiments on disaggregated.

**Load profile**:
A named k6 traffic shape driven at the frontend — e.g. `baseline`, `ramp`, `spike`,
`sustained`, `soak`. The unit in which traffic experiments are described.
_Avoid_: test, scenario, workload.

**Chaos experiment**:
A Chaos Mesh fault definition (pod kill, network partition, latency) applied to the fleet
or coordination plane. A **Schedule** turns experiments into the randomized, recurring
"chaos monkey."
_Avoid_: fault, attack, failure (too generic).

**Chaos annotation bridge**:
The component that turns Chaos Mesh fault events into Grafana annotations, so every
injected fault appears as a marker on the Dynamo dashboards next to its effect.

**Track G** / **Track N**:
The lab's two optional experiment tracks beyond the core A/B/C experiments (recover / autoscale /
spike). *Track G* observes **Grove** gang-scheduling GPU-free with the mocker (ADR 0009). *Track N*
— the NIXL KV-transfer data plane — is deferred because it needs real GPUs, so it breaks `$0` idle.
Both are additive: neither changes the default `make up` or the A/B/C roadmap.
_Avoid_: calling Track G "the Grove experiment" for anything data-plane — that is Track N.

**Grove**:
Dynamo's Kubernetes gang-scheduling / multi-component orchestration operator (opt-in, Track G).
It groups a fleet's components into a **gang** — a `PodCliqueSet` of `PodClique`s, plus a
`PodCliqueScalingGroup` for the prefill+decode unit — that the operator generates from the DGD.
The default lab does not install it.
_Avoid_: "PodGangSet" (renamed to PodCliqueSet); calling Grove the "scheduler" (that is KAI).

**Gang scheduling** (**KAI-Scheduler** / **PodGang**):
All-or-nothing placement: either every member of a gang is scheduled together or none is — no
partial deployment that deadlocks holding half the resources. Grove emits a `PodGang`; the
**KAI-Scheduler** places it. A gang that cannot fit shows as gang-blocked `Pending` — the Track G
signal, and what makes even node scaling (Karpenter) observable.
_Avoid_: "gang" for an ordinary Deployment's replicas — reserve it for a co-scheduled PodGang.

**Lifecycle verbs**:
- **up** / **down** — create / *fully destroy* the entire lab (Terraform + platform + fleet).
  `down` leaves nothing billing.
- **pause** / **resume** — scale nodes to zero / back, keeping the cluster, for cheap
  overnight suspension.
- **fleet-up** / **fleet-down** — deploy / remove just the Dynamo fleet on a live cluster
  (the fast inner loop).
_Avoid_: using start/stop for infra lifecycle — reserve **start**/**stop** for the chaos and
load services.
