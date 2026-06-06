output "connect_instance_id" {
  description = "Amazon Connect instance ID. Consumed by every downstream telephony PRD."
  value       = aws_connect_instance.main.id
}

output "connect_instance_arn" {
  description = "Amazon Connect instance ARN."
  value       = aws_connect_instance.main.arn
}

output "connect_instance_url" {
  description = "Connect admin console URL."
  value       = "https://${aws_connect_instance.main.instance_alias}.my.connect.aws"
}

output "admin_security_profile_id" {
  description = "Platform-Admin security profile ID. Consumed by PRD-50 for admin user provisioning."
  value       = aws_connect_security_profile.platform_admin.security_profile_id
}

output "agent_security_profile_id" {
  description = "Agent-Default security profile ID. Consumed by PRD-50 for agent provisioning."
  value       = aws_connect_security_profile.agent_default.security_profile_id
}

output "contact_flow_log_group_name" {
  description = "CloudWatch log group for Connect contact flow logs. Consumed by PRD-14 and PRD-91."
  value       = aws_cloudwatch_log_group.contact_flow_logs.name
}

output "placeholder_recordings_bucket" {
  description = "Placeholder recording bucket name. PRD-30 updates this storage association to the full storage architecture."
  value       = aws_s3_bucket.recordings_placeholder.bucket
}
