# Amazon EKS as the substrate for a GPU-free lab

We need to observe fleet-scale **failure recovery** *and* **planner autoscaling**, all
GPU-free. We deploy on Amazon EKS with CPU-only node groups, rather than docker-compose on
EC2 or ECS Fargate.

## Why

Autoscaling and self-healing are the phenomena under study, and they only exist
authentically on an orchestrator: Dynamo's operator and planner target Kubernetes. On
docker-compose there is nothing for the planner to scale into; ECS is not a path Dynamo is
packaged for. GPU-free (mocker) workers keep the node groups cheap CPU instances, so EKS is
affordable for a lab.

## Consequences

- ~15–20 min and a few dollars per full `up`/`down` cycle. Mitigated by `down` = full
  destroy ($0 idle, see [0006](0006-s3-state-and-destroy-on-down.md)) and fast inner-loop
  `fleet-up`/`fleet-down` scripts.
- Rejected: **docker-compose on EC2** (no orchestrator → no real autoscaling), **ECS
  Fargate** (Dynamo not packaged for it → hand-built autoscaling glue).
