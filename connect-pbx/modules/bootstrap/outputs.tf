output "state_bucket_name" {
  description = "S3 bucket name. Used in backend blocks of all downstream components."
  value       = aws_s3_bucket.tfstate.bucket
}

output "state_bucket_arn" {
  description = "S3 bucket ARN. Used in IAM policies."
  value       = aws_s3_bucket.tfstate.arn
}

output "bootstrap_kms_key_arn" {
  description = "Bootstrap-scoped KMS key ARN. Used for bootstrap state only. Per environment keys defined in account baseline."
  value       = aws_kms_key.tfstate_bootstrap.arn
}

output "terraform_execution_role_arn" {
  description = "Terraform execution IAM role ARN. Consumed by PRD-01 GitHub Actions workflows."
  value       = aws_iam_role.terraform_execution.arn
}

output "github_oidc_provider_arn" {
  description = "GitHub OIDC provider ARN. Consumed by PRD-01 for workflow trust configuration."
  value       = aws_iam_openid_connect_provider.github.arn
}
