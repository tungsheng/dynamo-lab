# platform/grove — Grove gang-scheduling (Track G, GPU-free)

Installs [Grove](https://github.com/ai-dynamo/grove) — Dynamo's Kubernetes orchestration layer
that groups a fleet's components into a gang and a scaling group — plus the gang scheduler it
relies on, **KAI-Scheduler**. Track G observes gang scheduling and multi-level autoscaling of the
prefill+decode unit (and, with the KAI pin below, topology-aware placement) using the existing
**mocker** fleet, so it needs **no GPUs**. See ADR `docs/adr/0009-track-g-grove-gang-scheduling.md`.

Optional and **additive**: the default `make up` never installs it (ADR 0009). Track N / NIXL is
out of scope (it needs real GPUs).

Pins verified against the **Dynamo v1.3.0** compatibility matrix
(`docs/kubernetes/installation-guide.md@v1.3.0`): dynamo-platform 1.3.x requires Grove
**≥ v0.1.0-alpha.11** and KAI-Scheduler **≥ v0.13.4**; Grove *topology-aware* placement needs KAI
**≥ v0.15.2**, so we pin KAI **v0.15.2** to cover all three Track G observations.

- Namespaces: **grove-system** (operator — the chart has no hardcoded default, pass `-n`),
  **kai-scheduler** (scheduler — its own namespace; do not run workloads there).

## Files

| File                          | Installs       | Chart (OCI — no `helm repo add`)                          | Pin              |
|-------------------------------|----------------|-----------------------------------------------------------|------------------|
| `values-grove-operator.yaml`  | Grove operator | `oci://ghcr.io/ai-dynamo/grove/grove-charts`              | `v0.1.0-alpha.11`|
| `values-kai-scheduler.yaml`   | KAI-Scheduler  | `oci://ghcr.io/kai-scheduler/kai-scheduler/kai-scheduler` | `v0.15.2`        |

Grove's CRDs (`grove.io/v1alpha1` + `scheduler.grove.io/v1alpha1`) ship inside its chart's `crds/`
and install automatically. The operator turns a DGD's `services` into Grove `PodCliqueSet` /
`PodClique` / `PodCliqueScalingGroup` (the older *PodGangSet* name is gone); Grove emits a
`PodGang` that KAI places all-or-nothing. **We author none of those** — only the two installs and
the existing DGD.

## Enablement contract with the Dynamo operator (must match)

Confirmed against `docs/kubernetes/{grove,installation-guide,deployment/multinode-deployment}.md`
@ v1.3.0. Two layers:

1. **Operator install flags** on the `dynamo-platform` Helm release (work item 2, gated behind
   `GROVE=1`): set `global.grove.enabled=true` + `global.kai-scheduler.enabled=true` — the
   "production" path, where Grove/KAI are installed separately (as this folder does). The bundled
   alternative is `global.grove.install=true` + `global.kai-scheduler.install=true`, which makes
   the platform chart install them as subcharts (simpler, but unpinned and less observable — we
   take the explicit path to match how the lab pins every other component).
2. **Grove is selected by DEFAULT** once its API is present — there is no per-DGD "enable" field,
   so the same `fleet/disagg.yaml` reconciles through Grove as-is. To opt *out* (fall back to
   LWS), set annotation `nvidia.com/enable-grove: "false"` on the DGD.

**Queue-name contract (the load-bearing gotcha).** The operator labels fleet pods with the KAI
queue from DGD annotation `nvidia.com/kai-scheduler-queue` (default **`dynamo`**), but KAI only
auto-creates a leaf queue named **`default-queue`**. A pod pointing at a non-existent queue never
schedules. Track G must either **(a)** create a KAI leaf `Queue` named `dynamo`, or **(b)** set the
DGD annotation to `default-queue`. Resolved in the fleet overlay (work item 3).

> VERIFY (live — cannot check statically): confirm the operator's default
> `nvidia.com/kai-scheduler-queue` value and KAI's default queue name on the pinned releases, then
> pick (a) or (b). Render-verify both charts with `helm template` on K8s 1.36 before live use.
> Re-pin Grove/KAI if you bump the Dynamo release — Grove APIs are pre-stable alpha and move in
> lockstep with dynamo-platform.

## Apply / remove (scripts will do this; shown for reference)

```sh
# Track G is opt-in; install_grove() (work item 2) runs only when GROVE=1.
helm upgrade --install grove oci://ghcr.io/ai-dynamo/grove/grove-charts \
  --version v0.1.0-alpha.11 -n grove-system --create-namespace \
  -f platform/grove/values-grove-operator.yaml
helm upgrade --install kai-scheduler oci://ghcr.io/kai-scheduler/kai-scheduler/kai-scheduler \
  --version v0.15.2 -n kai-scheduler --create-namespace \
  -f platform/grove/values-kai-scheduler.yaml

# remove
helm uninstall grove -n grove-system
helm uninstall kai-scheduler -n kai-scheduler
```

## Verify

```sh
kubectl -n grove-system get pods                        # operator running
kubectl -n kai-scheduler get pods                       # scheduler running
kubectl -n dynamo get podcliquesets,podcliques,podcliquescalinggroups   # the gang tree
kubectl -n dynamo get podgangs.scheduler.grove.io       # the scheduler-facing PodGang
kubectl -n dynamo get pods --field-selector=status.phase=Pending        # gang-blocked pods
```

> With Grove active, killing one gang member (chaos, experiment A) should make the operator
> reconcile the **whole gang**, not just the pod — the Track-G-specific thing to watch.
