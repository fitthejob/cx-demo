resource "aws_cloudwatch_metric_alarm" "drift_detected" {
  count = var.enable_drift_detected_alarm ? 1 : 0

  alarm_name          = "${var.org_name}-routing-drift-detected-${terraform.workspace}"
  alarm_description   = "PRD-19 routing drift detected for two consecutive scan periods."
  namespace           = local.metric_namespace
  metric_name         = "RoutingDriftCount"
  statistic           = "Maximum"
  period              = 900
  evaluation_periods  = 2
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = var.alarm_action_arns
  ok_actions          = var.alarm_action_arns

  tags = local.common_tags
}

resource "aws_cloudwatch_metric_alarm" "persistent_drift" {
  count = var.enable_persistent_drift_alarm ? 1 : 0

  alarm_name          = "${var.org_name}-routing-drift-persists-${terraform.workspace}"
  alarm_description   = "PRD-19 routing drift has persisted for four hours."
  namespace           = local.metric_namespace
  metric_name         = "RoutingDriftCount"
  statistic           = "Maximum"
  period              = 900
  evaluation_periods  = 16
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = var.alarm_action_arns
  ok_actions          = var.alarm_action_arns

  tags = local.common_tags
}
