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
- **Metrics** — workers set `DYN_SYSTEM_PORT=8081` and expose a `metrics` container port;
  `dynamo_component_*` metrics (incl. `dynamo_component_inflight_requests`) are served on
  `/metrics:8081`. Frontend serves `/metrics` on `:8000`. (The `monitoring` stack's
  PodMonitor/ServiceMonitor discovery scrapes these.)
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
  local/dry-run where no operator is present. Config uses load-scaling only
  (`optimization_target: none`) to stay backend-agnostic for the mocker.
- **HuggingFace token** — none. `Qwen/Qwen3-0.6B` is public. If HF rate-limits tokenizer
  pulls, create `hf-token-secret` (key `HF_TOKEN`) in ns `dynamo` and add
  `envFromSecret: hf-token-secret` to each worker service.

## VERIFY — version-sensitive assumptions (confirm against the pinned Dynamo release)

1. **Image tag** — all containers use `nvcr.io/nvidia/ai-dynamo/dynamo-planner:my-tag`.
   Replace `my-tag` with the pinned `${DYNAMO_VERSION}`. Confirm this image carries the
   mocker wheel (`python3 -m dynamo.mocker`) AND runs CPU-only. (There is no dedicated
   `mocker-runtime` image; upstream directs mocker users to the `dynamo-planner` image.)
2. **etcd discovery-backend annotation** — `nvidia.com/dynamo-discovery-backend: etcd`.
   Recent Dynamo defaults to Kubernetes-native discovery (EndpointSlices +
   `DynamoWorkerMetadata` CRDs) and treats etcd as legacy. This lab pins a 3-node etcd
   coordination plane, so we opt into etcd discovery. Verify the exact annotation
   key/value against `docs/kubernetes/service-discovery.md`, and that the platform Helm
   chart is configured with the same etcd endpoint. Omit the annotation to use the default.
3. **`ETCD_ENDPOINTS` / `NATS_SERVER` env var names** — confirm these are the runtime's
   expected variable names, and whether the operator already injects the coordination-plane
   endpoints from the platform Helm chart (in which case our explicit values just reassert
   them). If the operator owns them, these can be dropped.
4. **Planner `--config` schema + mocker as a scaling target** — confirm the config keys
   (`environment`, `backend`, `optimization_target`, `enable_load_scaling`,
   `enable_throughput_scaling`, `load_adjustment_interval_seconds`) for the pinned release,
   and that `"backend": "mocker"` is accepted. The SLA planner path normally needs a real
   backend + profiling data; if mocker isn't a valid target, either use `"backend": "vllm"`
   with profile data or drive pool scaling manually for experiment (B).
5. **mocker `--planner-profile-data`** — upstream mocker examples pass
   `/workspace/components/src/dynamo/planner/tests/data/profiling_results/H200_TP1P_TP1D`
   (timing profile shipped in the image). Confirm this path exists in the pinned image, or
   drop the flag if the mocker no longer requires it.
6. **DGD `resources` schema** — confirm `cpu`/`memory` are accepted as top-level keys under
   `resources.requests` / `resources.limits`. Upstream examples only demonstrate `gpu` and
   `custom.<name>` (e.g. `requests.custom.ephemeral-storage`); if cpu/memory must go under
   `custom`, adjust accordingly.
7. **`--num-workers 1`** — per the shared spec; confirm the mocker accepts it (runs N
   in-process simulated workers). Upstream deploy examples scale via pod `replicas` instead.
8. **`--model-name`** — carried over from the upstream mocker example alongside
   `--model-path`. Confirm both are still valid flags; `--model-name` may be optional.
9. **`DYN_SYSTEM_PORT=8081`** — the operator often defaults this to `9090` in Kubernetes;
   the spec pins `8081`. Confirm the `monitoring` scrape config targets `8081`.

## Upstream provenance

Adapted from real upstream examples in `github.com/ai-dynamo/dynamo`:
`examples/backends/mocker/deploy/agg.yaml` and `.../disagg.yaml` (mocker command,
`--disaggregation-mode`, `--planner-profile-data`, `componentType`/`subComponentType`
field structure), with the `Planner` service and `DYN_ROUTER_MODE=kv` router pattern taken
from `examples/backends/vllm/deploy/{agg_router,disagg_planner}.yaml`. Upstream field names
are preserved; only values were adapted to this lab's namespace, coordination plane, model,
resources, and observability wiring.
