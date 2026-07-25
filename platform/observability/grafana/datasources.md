# Grafana datasources — how they are provisioned and wired

The lab does **not** hand-provision datasources with separate ConfigMaps. They are
declared inside `../values-kube-prometheus-stack.yaml` under `grafana`, so Helm
renders them at install time. Three datasources exist:

| Name       | Type       | uid          | URL (in-cluster)                                                        | Default |
|------------|------------|--------------|------------------------------------------------------------------------|---------|
| Prometheus | prometheus | `prometheus` | auto (chart)                                                           | yes     |
| Tempo      | tempo      | `tempo`      | `http://tempo.monitoring.svc.cluster.local:3200`                       | no      |
| Loki       | loki       | `loki`       | `http://loki.monitoring.svc.cluster.local:3100`                        | no      |

- **Prometheus** is created automatically by kube-prometheus-stack with
  `uid: prometheus` and stays the default. The vendored Dynamo dashboards use a
  `${datasource}` template variable of type *prometheus*, which resolves to it.
  k6 remote-writes load metrics into this same Prometheus.
- **Tempo** and **Loki** are added via `grafana.additionalDataSources`.

## Correlation wiring (the point of having all three)

```
                 exemplar (metric -> trace)
   Prometheus  ───────────────────────────────▶  Tempo
       ▲                                            │  trace -> logs (by trace_id)
       │  span-metrics / service-graph              ▼
       │  (Tempo metrics-generator remote_write)   Loki
       └───────────────  RED from traces  ─────────▶ ▲
                                                     │  logs -> trace (derivedFields)
                                                     └──────────────▶ Tempo
```

- **Metrics → Traces**: Prometheus stores exemplars (`exemplar-storage` feature
  flag). Latency panels with `exemplar: true` show clickable dots that open the
  span in Tempo.
- **Traces → Logs**: Tempo's `tracesToLogsV2` points at the Loki uid; a span links
  to its logs filtered by `trace_id`.
- **Traces → Metrics**: Tempo's `tracesToMetrics` points at the Prometheus uid.
- **Logs → Traces**: Loki's `derivedFields` regex extracts a `trace_id` from log
  lines and links to Tempo. Promtail also lifts `trace_id` into Loki
  structured-metadata for `{app_kubernetes_io_part_of="dynamo-lab"}` logs.
- **Service graph / RED-from-traces**: Tempo's metrics-generator remote-writes
  span-metrics + service-graph series into Prometheus (`serviceMap.datasourceUid:
  prometheus`).

## Prerequisites for the links to resolve

- The fleet must export OTLP traces to `tempo.monitoring.svc.cluster.local:4317`
  and emit `trace_id` in its logs (owned by the fleet manifests).
- The built-in Prometheus datasource uid must be `prometheus`
  (**VERIFY** against the pinned kube-prometheus-stack version — every cross-link
  above depends on it).

## Chaos & load annotations

The `lab-overview` dashboard reads Grafana **annotations** (built-in
`-- Grafana --` datasource), not a datasource query:

- tag `chaos` / `dynamo-lab` → red markers, posted by the **chaos-annotation
  bridge** when a Chaos Mesh experiment starts/stops.
- tag `k6` / `load` → yellow markers, optionally posted by the load runner when a
  profile begins.

Both post to the Grafana HTTP API (`POST /api/annotations`) using the admin
credentials in the values file.
