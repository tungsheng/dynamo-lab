# S3 remote state; `down` means full destroy

Terraform state lives in an S3 bucket with native S3 state locking (`use_lockfile = true`,
no DynamoDB table). The top-level `down` runs `terraform destroy` so that an idle lab costs
**$0**.

## Why

Cost safety depends on reliable teardown, and lost local state would leave an
un-destroyable, silently-billing EKS cluster. Durable, recoverable remote state protects
teardown; destroying by default prevents surprise bills on a lab that is only used
occasionally.

## Consequences

- The S3 bucket must exist before Terraform can use it, so `up` performs a one-time
  bootstrap (create bucket if absent).
- Next `up` pays the full cluster rebuild (~15–20 min); `pause`/`resume` (scale nodes to
  zero, keep the cluster) is the cheaper suspend-and-return middle ground.
- Rejected: **local state** (simplest, but one lost file = a silently-billing orphan
  cluster), **DynamoDB lock table** (no longer needed with native S3 locking).
