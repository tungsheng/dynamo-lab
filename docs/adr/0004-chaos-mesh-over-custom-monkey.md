# Chaos Mesh as the fault-injection engine

We inject random failures with Chaos Mesh (driven by its `Schedule` CRD for the recurring
"monkey" behaviour), rather than writing a custom chaos-monkey service.

## Why

Beyond pod kills, Chaos Mesh injects **network partitions and latency** — essential for
genuinely testing the coordination plane, where partitioning etcd or NATS is a truer and
more revealing failure than a clean process kill. `chaos-start`/`chaos-stop` become
apply/delete of a `Schedule`.

## Consequences

- Heavier install and a new CRD API to learn versus a shell script.
- Chaos Mesh does not annotate our Grafana, so a small **chaos annotation bridge** watches
  its events and posts Grafana annotations — every injected fault shows as a marker on the
  Dynamo dashboards next to its effect.
- Rejected: **custom monkey script** — matched the "start/stop service" framing but could
  only kill pods, missing the network-fault experiments that are the most instructive.
