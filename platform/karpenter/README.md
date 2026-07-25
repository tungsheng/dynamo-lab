# platform/karpenter — elastic worker node autoscaling

Karpenter provisions the fleet's **elastic worker capacity** (CPU families, spot + on-demand).
The 2x `m7i.large` system managed node group (terraform) keeps hosting controllers and the
observability stack; Karpenter only grows/shrinks the worker nodes so a large enough traffic
spike scales pods and then **nodes**. See ADR `docs/adr/0008-karpenter-node-autoscaling.md`.

- Namespace: **karpenter** (controller)
- **Split of responsibilities:**
  - `terraform/main` — installs the Karpenter controller (helm_release, chart
    `oci://public.ecr.aws/karpenter/karpenter`) and, via the EKS module's `karpenter`
    submodule, the IAM/IRSA, interruption SQS queue, and node IAM role.
  - **This folder** — the `NodePool` and `EC2NodeClass` manifests, applied by scripts with
    `kubectl apply` during `make platform-up` (NOT by terraform).

## Files

| File                | Kind          | API (VERIFY)              |
|---------------------|---------------|---------------------------|
| `nodepool.yaml`     | NodePool      | `karpenter.sh/v1`         |
| `ec2nodeclass.yaml` | EC2NodeClass  | `karpenter.k8s.aws/v1`    |

## Discovery contract with terraform (must match)

`ec2nodeclass.yaml` discovers infra by tag:

- Subnets and security group tagged **`karpenter.sh/discovery: dynamo-lab`**.
- Node IAM role name substituted into `spec.role` via `${KARPENTER_NODE_ROLE}` (envsubst by
  the scripts layer, fed from the terraform karpenter submodule output).

> VERIFY: the discovery tag **key** and the node-role output name against what
> `terraform/main` actually emits. The EKS Karpenter submodule conventionally uses
> `karpenter.sh/discovery = <cluster_name>`; confirm the VPC/EKS terraform tags the private
> subnets and cluster security group with it.

## Apply / remove (scripts do this; shown for reference)

```sh
# Controller must already be installed by terraform (chart oci://public.ecr.aws/karpenter/karpenter).
# VERIFY: pin the Karpenter chart version in terraform (1.0.8 at build time).

export KARPENTER_NODE_ROLE="$(terraform -chdir=terraform/main output -raw karpenter_node_iam_role_name)"
envsubst < platform/karpenter/ec2nodeclass.yaml | kubectl apply -f -
kubectl apply -f platform/karpenter/nodepool.yaml

# remove
kubectl delete -f platform/karpenter/nodepool.yaml --ignore-not-found
kubectl delete -f platform/karpenter/ec2nodeclass.yaml --ignore-not-found
```

## Verify

```sh
kubectl get nodepool workers -o wide
kubectl get ec2nodeclass default -o wide
kubectl get nodeclaims                         # created as workloads schedule
kubectl -n karpenter logs deploy/karpenter -f  # watch provisioning decisions
```

> `make pause` scales this elastic capacity toward zero (and the system node group), `make
> resume` restores it — keeping the cluster while nothing bills overnight.
