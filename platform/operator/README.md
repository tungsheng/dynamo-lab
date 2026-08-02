# platform/operator — NVIDIA Dynamo Kubernetes Operator + CRDs

Installs the Dynamo Kubernetes Platform via the **platform** chart (`dynamo-platform`, which
contains the operator). See ADR `docs/adr/0002-operator-and-graph-deployment-crd.md`.

- Namespace: **dynamo-system**
- CRD API the fleet uses: `nvidia.com/v1beta1` (`DynamoGraphDeployment`); the operator's
  conversion webhook also serves the deprecated `nvidia.com/v1alpha1` at v1.3.0
- The operator reconciles the fleet declared in `fleet/agg.yaml` / `fleet/disagg.yaml`
  (namespace `dynamo`). We disable the operator's namespace restriction so a `dynamo-system`
  operator can manage DGDs in the `dynamo` namespace.
- We do **not** use the etcd/NATS bundled by this chart — the lab runs its own HA
  coordination plane (see `platform/coordination/`), so `values-dynamo-platform.yaml`
  disables them (`global.{etcd,nats}.install: false`) and points the operator at ours via
  `dynamo-operator.natsAddr` / `etcdAddr`.

## CRDs are managed by the operator (no separate chart)

Verified against **ai-dynamo/dynamo v1.3.0**: there is **no standalone `dynamo-crds` chart**.
The cluster-wide operator owns the CRDs and applies them from its own image via a `crd-apply`
init container (gated by `dynamo-operator.upgradeCRD`, default `true`). So the install is a
single `dynamo-platform` release — the earlier two-step `dynamo-crds`-then-`dynamo-platform`
flow is obsolete. (Sources: `docs/kubernetes/installation-guide.md`,
`docs/kubernetes/dynamo-operator.md`, `deploy/helm/charts/platform/Chart.yaml`.)

## Chart / version (pinned)

| Chart             | Repo                                             | Version |
|-------------------|--------------------------------------------------|---------|
| `dynamo-platform` | `https://helm.ngc.nvidia.com/nvidia/ai-dynamo`   | `1.3.0` |

> `dynamo-platform` 1.3.0 is the latest stable release (2026-07-22). Keep the platform
> version in step with the `DYNAMO_VERSION` used for the mocker image in `fleet/`. The NGC
> chart is served over **HTTPS** (`helm repo add`), not `oci://`.

## Install

```sh
# 1. Add the NGC Dynamo helm repo (public, no NGC API key needed for these charts).
helm repo add nvidia-ai-dynamo https://helm.ngc.nvidia.com/nvidia/ai-dynamo
helm repo update

# 2. Platform (operator). Our values disable bundled etcd/NATS, point the operator at the
#    lab's coordination plane, and let it watch all namespaces. The operator's crd-apply init
#    container installs the DynamoGraphDeployment CRDs automatically.
helm upgrade --install dynamo-operator nvidia-ai-dynamo/dynamo-platform \
  --version 1.3.0 \
  --namespace dynamo-system --create-namespace \
  -f platform/operator/values-dynamo-platform.yaml \
  --wait
```

> Release name per the shared spec: `dynamo-operator`. (The operator ships inside the
> `dynamo-platform` chart; we name that release `dynamo-operator`.)

## Uninstall

```sh
helm uninstall dynamo-operator -n dynamo-system
# CRDs installed by the operator are cluster-scoped and are NOT removed by the helm uninstall;
# delete them explicitly if you want them gone (this also deletes any remaining DGDs):
#   kubectl get crd -o name | grep nvidia.com | xargs -r kubectl delete
```

## Verify

```sh
kubectl -n dynamo-system get deploy,pods
kubectl get crd | grep nvidia.com          # expect dynamographdeployments.nvidia.com, etc.
# Operator controller deployment name (check the actual name in your release):
kubectl -n dynamo-system logs deploy/dynamo-operator-controller-manager
```
