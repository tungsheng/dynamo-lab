# platform/observability

The monitoring core for dynamo-lab, all in the **`monitoring`** namespace. Four
Helm releases plus a set of Grafana dashboard ConfigMaps. Everything here is
applied by `make platform-up` (the scripts+make agent owns the exact `helm`
invocations; this folder only holds the values and dashboards they consume).

## What's here

| File / dir                                   | Release / purpose                                                                 |
|----------------------------------------------|-----------------------------------------------------------------------------------|
| `values-kube-prometheus-stack.yaml`          | `kube-prometheus-stack` — Prometheus + Grafana + node/kube-state exporters.        |
| `values-loki.yaml`                           | `loki` — single-binary log store.                                                  |
| `values-tempo.yaml`                          | `tempo` — single-binary trace store, OTLP on 4317/4318.                            |
| `values-promtail.yaml`                       | `promtail` — DaemonSet shipping pod logs → Loki.                                   |
| `grafana/datasources.md`                     | How the three datasources are provisioned and cross-linked.                        |
| `grafana/dashboards/*.yaml`                  | Vendored Dynamo dashboards (dynamo, disagg, planner, operator) as ConfigMaps.      |
| `grafana/lab-overview-dashboard-configmap.yaml` | Custom overview: k6 load + chaos markers + fleet/planner/router metrics.        |

## Install order (handled by `make platform-up`)

```
helm upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
    -n monitoring -f values-kube-prometheus-stack.yaml
helm upgrade --install loki     grafana/loki     -n monitoring -f values-loki.yaml
helm upgrade --install tempo    grafana/tempo    -n monitoring -f values-tempo.yaml
helm upgrade --install promtail grafana/promtail -n monitoring -f values-promtail.yaml
kubectl apply -n monitoring -f grafana/dashboards/ -f grafana/lab-overview-dashboard-configmap.yaml
```

kube-prometheus-stack goes first because Loki/Tempo/Promtail expose
ServiceMonitors it must discover, and Grafana (part of the stack) is where all
dashboards and datasources live.

## How the pieces connect

```
   k6 (ns load) ──remote-write──▶ Prometheus ◀──scrape── Dynamo fleet PodMonitor* (ns dynamo)
                                     ▲  ▲                 etcd / nats / chaos-mesh / karpenter
   fleet ──OTLP:4317──▶ Tempo ──span-metrics remote-write┘  │
   pods  ──stdout──▶ Promtail ──▶ Loki                       │
                                     ▼                        ▼
                                  Grafana  ◀── dashboards (ConfigMaps, sidecar-imported)
                                     ▲
        chaos-annotation bridge ─────┘  (POST /api/annotations, tag "chaos")
```

- **Metrics.** Prometheus scrapes everything (`serviceMonitorSelectorNilUsesHelmValues:
  false` + empty namespace selectors → cluster-wide discovery) and additionally
  **receives** k6's remote-write at
  `http://kube-prometheus-stack-prometheus.monitoring.svc.cluster.local:9090/api/v1/write`.
- **Traces.** The fleet exports OTLP to `tempo.monitoring.svc.cluster.local:4317`.
  Tempo's metrics-generator feeds span-metrics back into Prometheus.
- **Logs.** Promtail tails every node and ships to
  `loki.monitoring.svc.cluster.local:3100`.
- **Correlation.** Datasources are cross-wired (exemplars, tracesToLogs,
  derivedFields) — see `grafana/datasources.md`.

## Accessing Grafana

Grafana is `ClusterIP` only (no load balancer — this is a lab). `make dashboards`
port-forwards `svc/kube-prometheus-stack-grafana`. Login: `admin` /
`dynamo-lab` (change it if this cluster is ever exposed — see the values file).

## Dashboards

The four `grafana/dashboards/*.yaml` ConfigMaps are vendored **verbatim** from the
upstream Dynamo repo (`deploy/observability/`), with only the
`app.kubernetes.io/part-of: dynamo-lab` label added. Re-sync them when bumping the
pinned Dynamo version. The custom `lab-overview` is the one to open first during an
experiment — it lines the injected fault (red annotation) up against queue depth,
error rate, planner replica moves, and latency recovery on a single screen.

## Notes / caveats

- **Promtail vs Alloy.** Promtail is in maintenance/LTS; Grafana Alloy is the
  modern replacement. Promtail is deliberately kept here for lab simplicity — see
  the comment at the top of `values-promtail.yaml`.
- **Single-binary Loki/Tempo, no object store, short retention** (7d logs/metrics,
  48h traces). Fine for a lab; not a production topology.
- **Fleet PodMonitor** (`*` above). The Dynamo operator is not confirmed to ship a
  PodMonitor for the mocker fleet (fleet/README.md flags this unverified), so this lab
  provides `podmonitor-fleet.yaml`. Its selector label + metrics port carry `# VERIFY`
  markers — confirm them against the running fleet pods.
- **`# VERIFY` markers** in each file flag version-sensitive assumptions (chart
  versions, the `prometheus` datasource uid, k6/Karpenter/kube-state metric names).
  Resolve them against the pinned chart/tool versions at build time.
