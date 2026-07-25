# Dynamo Lab

A **GPU-free** experimentation lab for [NVIDIA Dynamo](https://github.com/ai-dynamo/dynamo),
deployed to Amazon EKS, built to *watch* an inference **fleet**:

- **(A) recover from failure** — chaos injects pod kills, network partitions, and latency
- **(B) autoscale** — the Dynamo planner scales workers; Karpenter scales nodes
- **(C) hold up under traffic spikes** — programmable k6 load profiles

Workers are simulated with Dynamo's **mocker** engine, so the whole thing runs on cheap
CPU-only nodes — no GPUs. See [`CONTEXT.md`](CONTEXT.md) for the vocabulary,
[`docs/adr/`](docs/adr/) for why each choice was made, and [`PROGRESS.md`](PROGRESS.md) for
build status and the checklist to resolve before the first `make up`.

## Architecture

```
 k6 (spike profiles) ──HTTP──▶ Frontend (OpenAI API) + KV-aware Router
                                        │
                          ┌─────────────┴──────────────┐
                          ▼                             ▼
                   Prefill workers               Decode workers      ← mocker (GPU-free)
                   (disagg profile)              (agg = one pool)
                          │  planner autoscales pods ▲  │
                          ▼                          │  ▼
                   etcd (HA×3, leases/discovery) ── NATS (HA cluster, KV events)
                          ▲                                   ▲
              Chaos Mesh injects faults here (kill / partition / latency)
                          │
     Prometheus + Grafana + Loki (logs) + Tempo (traces)  ◀── everything scrapes/ships here
     Karpenter grows nodes when pods outgrow them
```

## Prerequisites

- An AWS account + credentials (`aws sts get-caller-identity` works)
- `terraform`, `kubectl`, `helm`, `aws` CLIs
- `k6` (only needed if you run load from your laptop instead of in-cluster)

## Quickstart

```bash
# Stand up everything: state bucket → EKS (Terraform) → platform (Helm) → fleet (CRD)
make up

# Deploy / swap the fleet topology on a live cluster (fast inner loop)
make fleet-up PROFILE=agg      # or PROFILE=disagg (the headline experiment)
make fleet-down

# Start / stop the chaos monkey (Chaos Mesh Schedule)
make chaos-start
make chaos-stop

# Start / stop a traffic spike (k6)
make load-start PROFILE=spike  # baseline | ramp | spike | sustained | soak
make load-stop

# Open Grafana
make dashboards

# Suspend cheaply overnight (scale nodes to 0, keep the cluster)
make pause
make resume

# Tear it ALL down — idle cost returns to $0
make down
```

Run `make help` for the full target list.

## Layout

| Path | What's here |
|---|---|
| `terraform/bootstrap/` | One-time S3 state bucket (local state) |
| `terraform/main/` | VPC, EKS, Karpenter, IAM — the cluster (S3 backend) |
| `platform/operator/` | Dynamo operator + CRDs (Helm) |
| `platform/observability/` | Prometheus, Grafana, Loki, Tempo + Dynamo dashboards |
| `platform/chaos-mesh/` | Chaos Mesh install |
| `platform/karpenter/` | Karpenter `NodePool` / `EC2NodeClass` |
| `fleet/` | `DynamoGraphDeployment` CRDs (`agg.yaml`, `disagg.yaml`) |
| `chaos/` | Chaos Mesh experiments/Schedules + Grafana annotation bridge |
| `load/` | k6 scripts and spike profiles |
| `scripts/` | Implementation behind the `make` targets |

## Configuration

Copy `terraform/main/example.tfvars` to `terraform/main/dev.tfvars` and edit. The most
important knob:

- **`region`** — defaults to `us-west-2`.

## Known things to verify against your pinned Dynamo release

Dynamo's repo layout and CRD schema move between versions, so the fleet manifests and the
mocker image tag are pinned and marked with `# VERIFY:` comments:

1. **CPU-only images** — confirm the mocker/frontend run on plain CPU nodes without
   requiring `nvidia.com/gpu` scheduling (the `dynamo-planner` image carries the mocker
   wheel and is CPU-oriented).
2. **Planner ↔ mocker ↔ k8s autoscaling** — confirm the planner's `KubernetesConnector`
   scales mocker worker replicas from load metrics; `VirtualConnector` is the documented
   fallback.
