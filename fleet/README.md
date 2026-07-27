# fleet/ — the Dynamo inference fleet

The **fleet** is the set of Dynamo components serving inference as one unit — Frontend
(OpenAI API + KV-aware router), Planner (autoscaler), and worker pool(s) — declared as a
single `DynamoGraphDeployment` (DGD) and reconciled by the Dynamo operator in
`dynamo-system`. See `../CONTEXT.md` for vocabulary and `../docs/adr/0002` / `0007` for why.

Workers are Dynamo's GPU-free **mocker** (`python3 -m dynamo.mocker`): the real
router/planner code path, with KV-cache management and prefill/decode timing *simulated*
instead of executing a model. No GPUs, no model weights — only `Qwen/Qwen3-0.6B`'s
tokenizer/config are pulled.

## Two profiles

| File | Topology | Worker pools | Use |
|------|----------|--------------|-----|
| `agg.yaml` | **Aggregated** | one pool (`MockerWorker`), each worker does prefill **and** decode | bring-up / scaffolding; the default (`fleet-up PROFILE=agg`) |
| `disagg.yaml` | **Disaggregated** | two pools (`MockerPrefillWorker`, `MockerDecodeWorker`) exchanging KV cache | the headline experiments (`fleet-up PROFILE=disagg`) |

The lab brings up on **aggregated** to prove the scaffolding, then runs its headline
failure/autoscale/spike experiments on **disaggregated**, where prefill and decode scale
independently and "kill a prefill worker" vs "kill a decode worker" are different failure
stories (ADR 0007). Both are the same mocker image, so carrying two profiles is cheap.

Applied by the scripts+make layer:

```
make fleet-up PROFILE=agg      # kubectl apply -f fleet/agg.yaml
make fleet-up PROFILE=disagg   # kubectl apply -f fleet/disagg.yaml
make fleet-down                # kubectl delete the applied DGD
```

Both DGDs live in namespace **`dynamo`** alongside the coordination plane (etcd + NATS).

## How the fleet is wired (both profiles)

- **KV-aware routing ON** — Frontend `DYN_ROUTER_MODE=kv`. Requires the NATS event plane:
  workers publish KV-cache events that the router consumes to route to the best worker.
- **Coordination plane** — every service gets the shared-spec DNS via env:
  - `ETCD_ENDPOINTS=http://etcd.dynamo.svc.cluster.local:2379` (service discovery)
  - `NATS_SERVER=nats://nats.dynamo.svc.cluster.local:4222` (KV event plane)
- **Metrics** — every service exposes a `metrics` container port on `:8081` and binds it:
  workers and Frontend via `DYN_SYSTEM_PORT=8081`, the Planner via `PLANNER_PROMETHEUS_PORT=8081`
  (verified v1.3.0 — the Planner serves Prometheus metrics on `PLANNER_PROMETHEUS_PORT`, default
  9085, not `DYN_SYSTEM_PORT`; the Frontend must have `DYN_SYSTEM_PORT` set on itself, not just
  the workers). `dynamo_component_*` metrics (incl. `dynamo_component_inflight_requests`) are
  served there. (The `monitoring` stack's PodMonitor discovery scrapes port name `metrics`.)
- **Tracing** — OTLP traces exported to Tempo over gRPC:
  `OTEL_EXPORT_ENABLED=true`, `OTEL_EXPORTER_OTLP_TRACES_ENDPOINT=http://tempo.monitoring.svc.cluster.local:4317`,
  `OTEL_EXPORTER_OTLP_PROTOCOL=grpc`. Logs are emitted as JSONL (`DYN_LOGGING_JSONL=true`)
  to stdout and shipped to Loki by promtail.
- **Worker resources** — `requests cpu 250m / mem 512Mi`, `limits cpu 1 / mem 1Gi`.
  Deliberately small so the operator/planner scale the pool in fine-grained pod increments.
- **Speedup ratio** — mocker `--speedup-ratio` is fed from env `DYN_MOCKER_SPEEDUP_RATIO`
  (default `10`) via Kubernetes `$(VAR)` arg expansion; override per deploy without editing
  the args.
- **Planner / autoscaling** — the `Planner` service runs `python3 -m dynamo.planner` with
  `"environment": "kubernetes"`, which selects the **KubernetesConnector**: the planner
  edits the DGD's service `replicas` through the Kubernetes API and the operator reconciles
  the pool. The fallback is the **VirtualConnector** (`"environment": "virtual"`) for
  local/dry-run where no operator is present. Config uses `optimization_target: throughput`
  (verified v1.3.0): for any non-`sla` target the planner force-enables load scaling and
  disables throughput scaling, giving backend-agnostic, load-driven autoscaling with no
  profiling data. (`load` would need explicit prefill/decode threshold keys, and `none` is not
  a valid target — both raise at config validation.)
- **HuggingFace token** — none. `Qwen/Qwen3-0.6B` is public. If HF rate-limits tokenizer
  pulls, create `hf-token-secret` (key `HF_TOKEN`) in ns `dynamo` and add
  `envFromSecret: hf-token-secret` to each worker service.

## Verified against ai-dynamo/dynamo v1.3.0

These version-sensitive assumptions were checked against the pinned release from primary
sources (upstream repo files at tag `v1.3.0`, the operator Go source, the planner Python
source, and docs.nvidia.com/dynamo). They are **docs/source-verified, not yet live-verified** —
re-check on the first real `make up`.

1. **Image** — `nvcr.io/nvidia/ai-dynamo/dynamo-planner:1.3.0` ships the `dynamo.mocker`
   module (`python3 -m dynamo.mocker`) and runs CPU-only (`docs/dynosim/mocker.md`;
   `examples/backends/mocker/deploy/agg.yaml`). There is no dedicated mocker image.
2. **etcd discovery-backend annotation** — `nvidia.com/dynamo-discovery-backend: etcd` opts
   into legacy KV-store discovery; Kubernetes-native discovery is the v1.3.0 default
   (`consts.go`; `docs/kubernetes/service-discovery.md`). Omit the annotation to use the default.
3. **`ETCD_ENDPOINTS` / `NATS_SERVER`** — these are the operator's own env var names
   (`graph.go` `AddStandardEnvVars`). The operator also injects them from the platform chart's
   coordination plane; our explicit pod-spec values override (`MergeEnvs`) and are harmless.
4. **Planner `--config`** — all keys are real `PlannerConfig` fields and `"backend": "mocker"`
   is a valid target. `optimization_target` is `Literal["throughput","latency","load","sla"]`;
   we use `"throughput"` (the default) — `"load"` requires prefill/decode threshold keys and
   `"none"` is invalid, both raising at config validation (`planner_config.py`).
5. **mocker `--planner-profile-data`** — **optional** (default `None` → hardcoded polynomials).
   Kept to match upstream; the `H200_TP1P_TP1D` profile ships in the repo/image at v1.3.0.
6. **DGD `resources`** — `cpu`/`memory` are valid top-level keys under `requests`/`limits`
   (operator `ResourceItem`; CRD examples `"1000m"`/`"4Gi"`).
7. **`--num-workers 1`** — a valid mocker flag (default 1); upstream deploys scale via pod
   `replicas` instead, so `1` here is a harmless no-op kept per the shared spec.
8. **`--model-name`** — optional (defaults from `--model-path`); both are valid mocker flags,
   and upstream passes both as we do.
9. **`DYN_SYSTEM_PORT` / metrics ports** — the operator gives workers + Planner a stock system
   port of `9090`, and leaves the Frontend's system server **disabled by default**
   (`DYN_SYSTEM_PORT` defaults to `-1`). This lab sets `DYN_SYSTEM_PORT=8081` on the Frontend +
   workers and `PLANNER_PROMETHEUS_PORT=8081` on the Planner (metrics default `9085`), so every
   `metrics` port binds on `8081` and the PodMonitor scrapes land.

## Still to verify live (needs a running cluster)

- The **component-type pod labels** the operator actually stamps on running pods. The chaos
  selectors (`chaos/experiments/pod-kill-{prefill,decode}.yaml`) match the alpha-era form
  (`nvidia.com/dynamo-component-type: worker` + `dynamo-sub-component-type: prefill|decode`);
  native v1beta1 pods may instead carry `dynamo-component-type: prefill|decode` directly. Check
  a live pod's labels before relying on the selector pairing.

## Upstream provenance

Adapted from real upstream examples in `github.com/ai-dynamo/dynamo`:
`examples/backends/mocker/deploy/agg.yaml` and `.../disagg.yaml` (mocker command,
`--disaggregation-mode`, `--planner-profile-data`, `componentType`/`subComponentType`
field structure), with the `Planner` service and `DYN_ROUTER_MODE=kv` router pattern taken
from `examples/backends/vllm/deploy/{agg_router,disagg_planner}.yaml`. Upstream field names
are preserved; only values were adapted to this lab's namespace, coordination plane, model,
resources, and observability wiring.
