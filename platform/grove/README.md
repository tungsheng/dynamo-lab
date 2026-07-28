# platform/grove — Grove gang-scheduling (Track G, GPU-free)

Installs [Grove](https://github.com/NVIDIA/grove) — Dynamo's Kubernetes orchestration layer
that groups a fleet's components (frontend / prefill / decode / router) into a **gang** and a
scaling group — plus the gang scheduler it depends on, **KAI-Scheduler**. Track G observes
gang scheduling, multi-level autoscaling of the prefill+decode unit, and topology-aware
placement with the existing **mocker** fleet, so it needs **no GPUs**. See ADR
`docs/adr/0009-track-g-grove-gang-scheduling.md`.

This is an **optional, additive** track: the default `make up` never installs it (ADR 0009).
Bring it up explicitly (see below); Track N / NIXL is out of scope (needs real GPUs).

- Namespaces: **grove-system** (operator), **kai-scheduler** (scheduler) — both `# VERIFY:`.
- **Split of responsibilities:**
  - `platform.sh` `install_grove()` — installs the two Helm charts, gated behind `GROVE=1`
    (default off) so the default bring-up path is untouched. *(work item 2, not yet wired.)*
  - **This folder** — the Helm values for the Grove operator and KAI-Scheduler.
  - The **Dynamo operator** renders a `DynamoGraphDeployment` into Grove resources when Grove
    + a gang scheduler are present and the operator is told to use them (see the enablement
    contract below).

## Files

| File                          | Installs        | Chart (VERIFY)                    |
|-------------------------------|-----------------|-----------------------------------|
| `values-grove-operator.yaml`  | Grove operator  | `<grove-repo>/grove-operator`     |
| `values-kai-scheduler.yaml`   | KAI-Scheduler   | `<kai-repo>/kai-scheduler`        |

Grove custom resources (`PodClique` / `PodCliqueScalingGroup` / `PodGangSet`) are created by
the **Dynamo operator** from the DGD — this folder installs only the two controllers. The
Track G fleet overlay that drives them is `fleet/grove-scale.yaml` (work item 3).

## Enablement contract with the Dynamo operator (must match)

The Dynamo operator only emits Grove resources when told to. Resolve and pin the mechanism:

> VERIFY: how the pinned Dynamo release enables Grove-backed deployment — a
> `dynamo-operator` Helm value (e.g. a `grove.enabled` / scheduler-backend flag) and/or a DGD
> field. Until confirmed, `fleet/grove-scale.yaml` may reconcile via the default path and
> never form a gang. Confirm against the operator Go source + docs.nvidia.com/dynamo at the
> pinned tag.

> VERIFY: the Grove API **group/version** and resource names
> (`grove.io/v1alpha1`? `PodGangSet` vs `PodCliqueSet`) against the pinned Grove release.

## Apply / remove (scripts will do this; shown for reference)

```sh
# Track G is opt-in. install_grove() (work item 2) runs only when GROVE=1.
# VERIFY: pin both chart repos + versions before wiring this into platform.sh.

helm upgrade --install grove <grove-repo>/grove-operator \
  -n grove-system --create-namespace -f platform/grove/values-grove-operator.yaml
helm upgrade --install kai-scheduler <kai-repo>/kai-scheduler \
  -n kai-scheduler --create-namespace -f platform/grove/values-kai-scheduler.yaml

# remove
helm uninstall grove -n grove-system
helm uninstall kai-scheduler -n kai-scheduler
```

## Verify

```sh
kubectl -n grove-system get pods                 # operator running
kubectl -n kai-scheduler get pods                # scheduler running
kubectl get podgangsets -A                        # VERIFY: kind/plural
kubectl get pods -n dynamo -o wide                # watch a gang land all-or-nothing
kubectl get pods -n dynamo --field-selector=status.phase=Pending   # gang-blocked pods
```

> With Grove active, killing one gang member (chaos, experiment A) should make the operator
> reconcile the **whole gang**, not just the pod — the Track-G-specific thing to watch.
