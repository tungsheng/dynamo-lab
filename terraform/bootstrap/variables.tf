# terraform/bootstrap/variables.tf

variable "region" {
  description = "AWS region for the Terraform state bucket. Keep in sync with terraform/main's region."
  type        = string
  default     = "us-west-2"
}

variable "project" {
  description = "Project name, used as a tag and as the state-bucket name prefix."
  type        = string
  default     = "dynamo-lab"
}
