# platform/operator — NVIDIA Dynamo Kubernetes Operator + CRDs

Installs the Dynamo Kubernetes Platform: first the **CRDs** chart (`dynamo-crds`), then the
**platform** chart (`dynamo-platform`, which contains the operator). See ADR
`docs/adr/0002-operator-and-graph-deployment-crd.md`.

- Namespace: **dynamo-system**
- CRD API the fleet uses: `nvidia.com/v1alpha1` (`DynamoGraphDeployment`)
- The operator reconciles the fleet declared in `fleet/agg.yaml` / `fleet/disagg.yaml`
  (namespace `dynamo`). We disable the operator's namespace restriction so a `dynamo-system`
  operator can manage DGDs in the `dynamo` namespace.
- We do **not** use the etcd/NATS bundled by this chart — the lab runs its own HA
  coordination plane (see `platform/coordination/`), so `values-dynamo-platform.yaml`
  disables them.

## Charts / versions (pinned)

| Chart            | Repo                                             | Version (VERIFY) |
|------------------|--------------------------------------------------|------------------|
| `dynamo-crds`    | `https://helm.ngc.nvidia.com/nvidia/ai-dynamo`   | `0.9.1`          |
| `dynamo-platform`| `https://helm.ngc.nvidia.com/nvidia/ai-dynamo`   | `1.3.0`          |

> NGC "latest" at build time: `dynamo-crds` 0.9.1 (2026-03-04), `dynamo-platform` 1.3.0
> (2026-07-22). The three Dynamo charts (crds / platform / graph) version independently —
> always run `helm search repo nvidia-ai-dynamo --versions` before installing and keep the
> platform version in step with the `DYNAMO_VERSION` used for the mocker image in `fleet/`.
> The NGC charts are served over **HTTPS** (`helm repo add`), not `oci://`.

## Install

```sh
# 1. Add the NGC Dynamo helm repo (public, no NGC API key needed for these charts).
#    VERIFY: repo URL + that these charts are anonymous-pullable on the pinned release.
helm repo add nvidia-ai-dynamo https://helm.ngc.nvidia.com/nvidia/ai-dynamo
helm repo update

# 2. CRDs first (cluster-scoped; installed CRD contents are pinned to the release tag).
helm upgrade --install dynamo-crds nvidia-ai-dynamo/dynamo-crds \
  --version 0.9.1 \
  --namespace dynamo-system --create-namespace \
  --wait

# 3. Platform (operator). Uses our values to disable bundled etcd/NATS and watch all namespaces.
helm upgrade --install dynamo-operator nvidia-ai-dynamo/dynamo-platform \
  --version 1.3.0 \
  --namespace dynamo-system --create-namespace \
  -f platform/operator/values-dynamo-platform.yaml \
  --wait
```

> Release names per the shared spec: `dynamo-crds` and `dynamo-operator`. (The operator ships
> inside the `dynamo-platform` chart; we name that release `dynamo-operator`.)

## Uninstall

```sh
helm uninstall dynamo-operator -n dynamo-system
helm uninstall dynamo-crds     -n dynamo-system   # removes CRDs -> deletes any remaining DGDs
```

## Verify

```sh
kubectl -n dynamo-system get deploy,pods
kubectl get crd | grep nvidia.com          # expect dynamographdeployments.nvidia.com, etc.
kubectl -n dynamo-system logs deploy/dynamo-operator-controller-manager   # VERIFY: deploy name
```
