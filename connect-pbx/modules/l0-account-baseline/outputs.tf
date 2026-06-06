output "kms_key_arn" {
  description = "KMS key ARN for the current workspace environment. Used in all resource encryption and backend config."
  value       = aws_kms_key.env[terraform.workspace].arn
}

output "kms_key_alias" {
  description = "KMS key alias for the current workspace environment."
  value       = aws_kms_alias.env[terraform.workspace].name
}

output "permission_boundary_arn" {
  description = "IAM permission boundary managed ARN. Applied to all Lambda execution roles and service roles in downstream PRDs."
  value       = aws_iam_policy.platform_boundary.arn
}

output "access_analyzer_arn" {
  description = "IAM Access Analyzer ARN. Referenced by PRD-03 for finding aggregation."
  value       = aws_accessanalyzer_analyzer.account.arn
}

output "connect_service_linked_role_arn" {
  description = "Amazon Connect service-linked role ARN. Referenced by PRD-10."
  value       = local.connect_service_linked_role_arn
}
