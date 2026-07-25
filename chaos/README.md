# chaos/ — fault injection for the Dynamo fleet

Chaos Mesh experiments, the recurring "chaos monkey," and the annotation bridge that
draws every injected fault onto the Grafana dashboards. Rationale in
[`docs/adr/0004-chaos-mesh-over-custom-monkey.md`](../docs/adr/0004-chaos-mesh-over-custom-monkey.md).

Everything here targets namespace **`dynamo`** — the fleet (frontend, KV-aware router,
workers, planner) plus the coordination plane (etcd, NATS). Chaos Mesh itself lives in
namespace `chaos-mesh` and must be installed (via `make platform-up`) first.

## Layout

```
chaos/
  experiments/                     # standalone, apply-one-at-a-time faults
    pod-kill-decode.yaml           # kill a random decode worker
    pod-kill-prefill.yaml          # kill a random prefill worker (disagg only)
    pod-kill-etcd.yaml             # kill one etcd member (quorum survives)
    pod-kill-nats.yaml             # kill one NATS node (cluster survives)
    netpart-workers-nats.yaml      # cut workers off from the KV event plane
    netpart-etcd-member.yaml       # isolate one etcd member from its peers
    net-latency-router-worker.yaml # add latency on Frontend/router -> worker
  schedule-monkey.yaml             # the chaos monkey (a set of Schedules)
  annotation-bridge/               # chaos events -> Grafana annotations
    configmap.yaml                 # the watcher script (bridge.py)
    rbac.yaml                      # ServiceAccount + Role/RoleBinding
    secret.example.yaml            # Grafana credentials PLACEHOLDER (copy, don't apply as-is)
    deployment.yaml                # the bridge Deployment
  README.md
```

## The three experiment categories

| Category | Files | What it reveals |
|----------|-------|-----------------|
| Worker pod kill | `pod-kill-decode`, `pod-kill-prefill` | Reschedule + re-register latency; router reroute while a replacement rejoins. |
| Coordination-plane fault | `pod-kill-etcd`, `pod-kill-nats`, `netpart-etcd-member`, `netpart-workers-nats` | Graceful degradation of the HA quorum (ADR-0003); KV-aware routing going blind when NATS is unreachable though no pod died. |
| Path latency | `net-latency-router-worker` | How added hop latency surfaces in TTFT / inter-token latency and whether the router rebalances. |

Pod kills self-recover by rescheduling. Network experiments carry a `duration` so they
self-heal — a Schedule run always leaves the fleet recovered.

## How pods are selected

Workers and the frontend are matched by the Dynamo operator's **name-independent**
workload-selector labels, so the same files work for both `mocker-agg` and
`mocker-disagg`:

- workers: `nvidia.com/dynamo-component-type: worker`
  (+ `nvidia.com/dynamo-sub-component-type: decode|prefill`)
- frontend/router: `nvidia.com/dynamo-component-type: frontend`

Coordination plane is matched by Helm chart labels:

- etcd: `app.kubernetes.io/name: etcd`
- nats: `app.kubernetes.io/name: nats`

See the `# VERIFY` comments in each file — the exact operator label keys/values are
version-sensitive.

## Running a single experiment

```sh
kubectl apply  -f chaos/experiments/pod-kill-decode.yaml
kubectl -n dynamo get podchaos,networkchaos
kubectl -n dynamo describe podchaos pod-kill-decode   # see selected targets + phase
kubectl delete -f chaos/experiments/pod-kill-decode.yaml
```

## The chaos monkey (`chaos-start` / `chaos-stop`)

`schedule-monkey.yaml` bundles several `Schedule` resources that fire the experiments at
staggered cron intervals with `mode: one` (Chaos Mesh picks a random victim each run), so
over time the monkey mixes pod kills, latency, and partitions:

| Schedule | Interval | Fault |
|----------|----------|-------|
| `monkey-pod-kill-worker` | every 10 min | random worker pod-kill |
| `monkey-pod-kill-coordination` | :03/:33 | random etcd **or** nats pod-kill |
| `monkey-latency-router-worker` | :07/:27/:47 | 2 min router→worker latency |
| `monkey-netpart-workers-nats` | :15 hourly | 1 min worker↔NATS partition |

```sh
# make chaos-start
kubectl apply  -f chaos/schedule-monkey.yaml
# make chaos-stop
kubectl delete -f chaos/schedule-monkey.yaml
```

Deleting the Schedules stops new faults; any in-flight network fault clears at its
`duration`. To hard-stop everything immediately, also delete the generated objects:
`kubectl -n dynamo delete podchaos,networkchaos --all`.

## Chaos annotation bridge

The bridge (namespace `chaos-mesh`) watches Kubernetes Events for `chaos-mesh.org`
objects in `dynamo` and posts **Grafana annotations**, opening a region on the fault's
`Applied` event and closing it (`timeEnd`) on `Recovered`/`TimeUp`/`Deleted`. Result:
every fault is a shaded band on the Dynamo dashboards next to its effect.

Install:

```sh
# 1. Provide Grafana credentials (do NOT commit real ones):
kubectl -n chaos-mesh create secret generic chaos-annotation-bridge-grafana \
  --from-literal=GRAFANA_TOKEN=<grafana-service-account-token>
#    (or copy chaos/annotation-bridge/secret.example.yaml to secret.yaml, fill it in,
#     and apply it — chaos-start skips *example* files so the placeholder is never applied)

# 2. Apply RBAC + config + workload:
kubectl apply -f chaos/annotation-bridge/rbac.yaml
kubectl apply -f chaos/annotation-bridge/configmap.yaml
kubectl apply -f chaos/annotation-bridge/deployment.yaml
kubectl -n chaos-mesh logs deploy/chaos-annotation-bridge -f
```

Config via env (see `deployment.yaml`): `GRAFANA_URL` (defaults to the in-cluster Grafana
service), `WATCH_NAMESPACE` (`dynamo`), `ANNOTATION_TAGS`. Auth via the
`chaos-annotation-bridge-grafana` Secret — a Grafana service-account token (Bearer) is
preferred; basic auth (`GRAFANA_USER`/`GRAFANA_PASSWORD`) is the fallback. **VERIFY auth**:
kube-prometheus-stack's bundled Grafana defaults to `admin`/`prom-operator` unless
overridden.

### Alternative: annotate from Prometheus metrics (no bridge)

If you would rather not run the bridge, Chaos Mesh exports `chaos_mesh_*` metrics (enable
`controllerManager.metrics` / the Prometheus scrape on install). In Grafana, add a
dashboard **annotation query** of type *Prometheus* against a series such as
`chaos_mesh_experiments{status="injecting"}` (VERIFY exact metric/label names for your
Chaos Mesh version) and use a *step/region* mapping so active experiments render as bands.
This is lighter to operate but coarser — it shows *that* a fault type is active, not the
specific object name/target the bridge captures from Events.

## Notes

- The monkey and standalone experiments overlap by design — use standalone files for a
  controlled, single-fault observation and the monkey for continuous background churn.
- `pod-kill-prefill` and `netpart-etcd-member` matter most in the disaggregated /
  HA-quorum stories respectively; they no-op cleanly when their targets are absent.
