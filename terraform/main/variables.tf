# terraform/main/variables.tf

variable "region" {
  description = "AWS region for the whole lab."
  type        = string
  default     = "us-west-2"
}

variable "project" {
  description = "Project name; used for tagging and naming."
  type        = string
  default     = "dynamo-lab"
}

variable "cluster_name" {
  description = "EKS cluster name."
  type        = string
  default     = "dynamo-lab"
}

variable "cluster_version" {
  description = "Kubernetes control-plane version."
  type        = string
  default     = "1.31" # VERIFY: latest stable EKS version at build time (1.32/1.33 may be GA)
}

variable "vpc_cidr" {
  description = "CIDR for the lab VPC."
  type        = string
  default     = "10.0.0.0/16"
}

variable "az_count" {
  description = "Number of availability zones to spread the VPC across."
  type        = number
  default     = 3
}

variable "system_node_instance_type" {
  description = "Instance type for the system managed node group (controllers + observability)."
  type        = string
  default     = "m7i.large"
}

variable "system_node_desired_size" {
  description = "Desired size of the system managed node group. Default 3 so the etcd 3-member quorum (hard podAntiAffinity, ADR 0003) can schedule across distinct nodes."
  type        = number
  default     = 3
}

variable "system_node_min_size" {
  description = "Minimum size of the system managed node group. Default 3 to keep the etcd 3-member quorum schedulable (ADR 0003). `make pause` does NOT change this variable; it scales the node group imperatively via `aws eks update-nodegroup-config` (the next `terraform apply` reconciles that drift back to this value)."
  type        = number
  default     = 3
}

variable "system_node_max_size" {
  description = "Maximum size of the system managed node group."
  type        = number
  default     = 3
}

variable "cluster_endpoint_public_access" {
  description = "Expose the EKS API endpoint publicly (convenient for a lab run from a laptop)."
  type        = bool
  default     = true
}

variable "cluster_endpoint_public_access_cidrs" {
  description = "CIDRs allowed to reach the public EKS API endpoint. Narrow this in a shared account."
  type        = list(string)
  default     = ["0.0.0.0/0"] # VERIFY: tighten to your egress IP/CIDR for anything but a throwaway lab
}

variable "tags" {
  description = "Extra tags merged onto all resources."
  type        = map(string)
  default     = {}
}
