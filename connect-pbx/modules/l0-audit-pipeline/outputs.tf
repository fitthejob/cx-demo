output "audit_bucket_name" {
  description = "Audit log S3 bucket name. CloudTrail, Config, and evidence export destination."
  value       = aws_s3_bucket.audit.bucket
}

output "audit_bucket_arn" {
  description = "Audit log S3 bucket ARN. Used in IAM policies for downstream services."
  value       = aws_s3_bucket.audit.arn
}

output "audit_access_logs_bucket_name" {
  description = "S3 server access logs bucket name for the audit bucket."
  value       = aws_s3_bucket.audit_access_logs.bucket
}

output "cloudtrail_trail_arn" {
  description = "CloudTrail trail ARN. Referenced by PRD-140 for additional event selectors."
  value       = aws_cloudtrail.main.arn
}

output "config_recorder_name" {
  description = "AWS Config recorder name. Referenced by PRD-140 for additional Config rules."
  value       = aws_config_configuration_recorder.main.name
}

output "security_hub_arn" {
  description = "Security Hub ARN. Referenced by PRD-140 for additional standards and integrations."
  value       = aws_securityhub_account.main.id
}

output "platform_alert_topic_arn" {
  description = "Platform alert SNS topic ARN. Used by all PRDs for alarm publishing. Populate SNS_ALERT_TOPIC_ARN GitHub secret after apply."
  value       = aws_sns_topic.platform_alerts.arn
}

output "cloudtrail_sns_topic_arn" {
  description = "CloudTrail log delivery notification SNS topic ARN. Consumed by PRD-91."
  value       = aws_sns_topic.cloudtrail.arn
}

output "config_sns_topic_arn" {
  description = "AWS Config notification SNS topic ARN. Consumed by PRD-91."
  value       = aws_sns_topic.config.arn
}
