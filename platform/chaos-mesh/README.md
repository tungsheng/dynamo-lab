# platform/chaos-mesh — Chaos Mesh fault-injection engine

Injects the lab's failures — pod kills, network partitions, latency — against the fleet and
the coordination plane. The recurring "chaos monkey" is a `Schedule` CRD (lives under
`chaos/`, applied by `make chaos-start`). See ADR
`docs/adr/0004-chaos-mesh-over-custom-monkey.md`.

- Namespace: **chaos-mesh**
- Dashboard + Prometheus metrics enabled (see `values-chaos-mesh.yaml`).
- A separate **chaos annotation bridge** turns Chaos Mesh events into Grafana annotations so
  every fault shows up next to its effect on the dashboards (that component lives elsewhere in
  the repo; this folder only installs Chaos Mesh itself).

## Install

```sh
helm repo add chaos-mesh https://charts.chaos-mesh.org
helm repo update
helm upgrade --install chaos-mesh chaos-mesh/chaos-mesh \
  --namespace chaos-mesh --create-namespace \
  -f platform/chaos-mesh/values-chaos-mesh.yaml \
  --wait
```

> VERIFY: pin a chart version (`helm search repo chaos-mesh/chaos-mesh --versions`) and confirm
> the containerd socket path in the values matches the EKS node AMI.

## Uninstall

```sh
helm uninstall chaos-mesh -n chaos-mesh
```

## Verify / dashboard

```sh
kubectl -n chaos-mesh get pods
kubectl get crd | grep chaos-mesh.org        # podchaos, networkchaos, schedules, ...
# Dashboard (securityMode disabled for the lab):
kubectl -n chaos-mesh port-forward svc/chaos-dashboard 2333:2333   # then open http://localhost:2333
```
