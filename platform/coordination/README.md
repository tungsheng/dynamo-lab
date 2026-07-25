# platform/coordination — HA coordination plane (etcd + NATS)

The two shared-state services the Dynamo fleet depends on, run **highly available** so chaos
experiments show graded degradation instead of a single on/off outage. See ADR
`docs/adr/0003-ha-coordination-plane.md`.

- Namespace: **dynamo** (same namespace as the fleet)
- **etcd** — service discovery via leases. 3-node quorum, auth disabled, metrics on.
  DNS: `http://etcd.dynamo.svc.cluster.local:2379`
- **NATS** — KV event plane for KV-aware routing. 3-node JetStream cluster, exporter on.
  DNS: `nats://nats.dynamo.svc.cluster.local:4222`

> To deliberately reproduce the single-SPOF story (ADR 0003), set `replicaCount: 1` /
> `config.cluster.replicas: 1` and re-apply.

## Install

```sh
kubectl create namespace dynamo --dry-run=client -o yaml | kubectl apply -f -

# etcd — bitnami OCI chart (no `helm repo add` needed for OCI).
# VERIFY: pin a chart version; check the image repo/tag in values-etcd.yaml still pulls
#         (bitnami -> bitnamilegacy migration, Aug 2025).
helm upgrade --install etcd oci://registry-1.docker.io/bitnamicharts/etcd \
  --namespace dynamo --create-namespace \
  -f platform/coordination/values-etcd.yaml \
  --wait

# NATS — official chart.
helm repo add nats https://nats-io.github.io/k8s/helm/charts/
helm repo update
helm upgrade --install nats nats/nats \
  --namespace dynamo --create-namespace \
  -f platform/coordination/values-nats.yaml \
  --wait
```

## Uninstall

```sh
helm uninstall nats -n dynamo
helm uninstall etcd -n dynamo
# PVCs from the StatefulSets are retained by design; delete them to fully reclaim:
# kubectl -n dynamo delete pvc -l app.kubernetes.io/instance=etcd
# kubectl -n dynamo delete pvc -l app.kubernetes.io/instance=nats
```

## Verify

```sh
kubectl -n dynamo get pods -l app.kubernetes.io/instance=etcd   # expect 3 Ready
kubectl -n dynamo get pods -l app.kubernetes.io/instance=nats   # expect 3 Ready
kubectl -n dynamo exec etcd-0 -- etcdctl endpoint health --cluster
kubectl -n dynamo exec nats-0 -- nats-server --help >/dev/null   # sanity
```
