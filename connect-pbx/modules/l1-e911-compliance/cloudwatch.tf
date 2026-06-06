resource "aws_cloudwatch_metric_alarm" "no_record" {
  count = var.enable_no_record_alarm ? 1 : 0

  alarm_name          = "${var.org_name}-agents-with-no-e911-record-${terraform.workspace}"
  alarm_description   = "PRD-18 active agents with no E911 record."
  namespace           = local.metric_namespace
  metric_name         = "AgentsWithNoE911Record"
  statistic           = "Maximum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = var.alarm_action_arns
  ok_actions          = var.alarm_action_arns

  tags = local.common_tags
}

resource "aws_cloudwatch_metric_alarm" "provider_sync_failure" {
  count = var.enable_sync_failure_alarm ? 1 : 0

  alarm_name          = "${var.org_name}-e911-provider-sync-failure-${terraform.workspace}"
  alarm_description   = "PRD-18 provider synchronization failures detected."
  namespace           = local.metric_namespace
  metric_name         = "E911ProviderSyncFailure"
  statistic           = "Sum"
  period              = 900
  evaluation_periods  = 3
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = var.alarm_action_arns
  ok_actions          = var.alarm_action_arns

  tags = local.common_tags
}

resource "aws_cloudwatch_metric_alarm" "notification_error" {
  count = var.enable_notification_error_alarm ? 1 : 0

  alarm_name          = "${var.org_name}-emergency-notification-errors-${terraform.workspace}"
  alarm_description   = "PRD-18 emergency notification Lambda execution errors."
  namespace           = "AWS/Lambda"
  metric_name         = "Errors"
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = var.alarm_action_arns
  ok_actions          = var.alarm_action_arns

  dimensions = {
    FunctionName = aws_lambda_function.emergency_notification.function_name
  }

  tags = local.common_tags
}
