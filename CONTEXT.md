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

**Lifecycle verbs**:
- **up** / **down** — create / *fully destroy* the entire lab (Terraform + platform + fleet).
  `down` leaves nothing billing.
- **pause** / **resume** — scale nodes to zero / back, keeping the cluster, for cheap
  overnight suspension.
- **fleet-up** / **fleet-down** — deploy / remove just the Dynamo fleet on a live cluster
  (the fast inner loop).
_Avoid_: using start/stop for infra lifecycle — reserve **start**/**stop** for the chaos and
load services.
