# terraform/bootstrap/outputs.tf

output "state_bucket_name" {
  description = "Name of the S3 bucket holding terraform/main remote state."
  value       = aws_s3_bucket.tfstate.id
}

output "state_bucket_region" {
  description = "Region the state bucket lives in."
  value       = var.region
}

output "account_id" {
  description = "AWS account ID (used in the bucket name)."
  value       = data.aws_caller_identity.current.account_id
}

# Convenience: the exact -backend-config flags terraform/main needs at init time.
output "backend_config_hint" {
  description = "Pass these to `terraform -chdir=terraform/main init` (the scripts do this automatically)."
  value = join(" ", [
    "-backend-config=bucket=${aws_s3_bucket.tfstate.id}",
    "-backend-config=key=main/terraform.tfstate",
    "-backend-config=region=${var.region}",
    "-backend-config=use_lockfile=true",
  ])
}
