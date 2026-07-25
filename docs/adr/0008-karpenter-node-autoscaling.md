# Karpenter for node autoscaling

The planner scales worker *pods*; a large enough traffic spike can exhaust a fixed node
group. We use Karpenter so that a big spike scales pods and then **nodes**, rather than
capping the fleet at a fixed node count.

## Why

It exposes a second scaling loop to observe ("the spike was so big even the cluster grew")
and removes the ceiling on spike experiments, so the planner's pod-scaling story never
silently hits a wall of `Pending` pods.

## Consequences

- Extra Terraform/IAM setup, and node-provisioning latency (~1–2 min) becomes part of what
  is observed — realistic, but a mild confound for the *pure* planner story.
- A small managed node group still hosts controllers and the observability stack; Karpenter
  provisions only the elastic worker capacity.
- Rejected: **fixed, generously-sized node group** — cleanest pure-planner story and simplest
  Terraform, but a hard ceiling under large spikes.
