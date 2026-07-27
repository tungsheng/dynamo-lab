# terraform/main/example.tfvars
#
# Copy to dev.tfvars and adjust. The scripts auto-load terraform/main/dev.tfvars via
# -var-file when it exists (override with TFVARS=<name>). All values have sane defaults in
# variables.tf; everything here is optional override.

region          = "us-west-2"
project         = "dynamo-lab"
cluster_name    = "dynamo-lab"
cluster_version = "1.36" # latest EKS standard-support version (verified 2026-07-27)

vpc_cidr = "10.0.0.0/16"
az_count = 3

# System managed node group (controllers + observability). Karpenter runs the workers.
# 3 nodes so the etcd 3-member quorum (hard podAntiAffinity, ADR 0003) can schedule.
system_node_instance_type = "m7i.large"
system_node_desired_size  = 3
system_node_min_size      = 3
system_node_max_size      = 3

# Lab-convenience public API endpoint. TIGHTEN this to your egress CIDR in a shared account.
cluster_endpoint_public_access       = true
cluster_endpoint_public_access_cidrs = ["0.0.0.0/0"]

tags = {
  owner = "dynamo-lab"
}
