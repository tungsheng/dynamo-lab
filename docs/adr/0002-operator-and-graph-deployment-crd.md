# Dynamo Operator + DynamoGraphDeployment CRD

The fleet must be declarative and self-healing. We install the Dynamo Kubernetes Operator
and declare the whole fleet as a single `DynamoGraphDeployment` (DGD), rather than
hand-rolling Helm charts or raw manifests per component.

## Why

Planner autoscaling and operator reconciliation are exactly the behaviours we want to
observe, and the operator provides them built-in. `fleet-up`/`fleet-down` reduce to
`kubectl apply`/`delete` of one CRD, and chaos gets richer — kill a CRD-managed worker and
watch the operator reconcile it; kill the operator and watch what stops healing.

## Consequences

- Dependency on the operator's evolving CRD API (now `nvidia.com/v1beta1`; `v1alpha1` is
  deprecated but still served via the conversion webhook at v1.3.0); the lab is pinned to a
  specific Dynamo release and CRD contents are verified against that tag.
- Rejected: **hand-rolled manifests** — would re-implement autoscaling and self-healing and
  diverge from how Dynamo is meant to run.
