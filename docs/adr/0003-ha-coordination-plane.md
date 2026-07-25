# Highly-available coordination plane (etcd + NATS)

etcd (service discovery via leases) and NATS (the KV event plane) are the fleet's single
points of failure, and with KV-aware routing enabled they sit on the request critical path.
We run both highly-available: a 3-node etcd quorum and a clustered NATS.

## Why

The lab's purpose is observing *how* the system handles failure, and HA is the only way to
see the difference between "survives a node loss" and "loses quorum." It turns chaos on the
coordination plane into a graded spectrum — degrade one node, lose quorum, total outage,
recover — instead of a single on/off.

## Consequences

- More moving parts and a little more CPU/memory than single-replica.
- Replica counts can be dialled to 1 to deliberately reproduce the single-SPOF story.
- Rejected: **single-replica etcd/NATS** — cheaper and simpler, but only a blunt
  outage-and-recovery demo with no graceful-degradation behaviour to watch.
