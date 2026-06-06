resource "aws_cloudwatch_metric_alarm" "submission_failure" {
  count = var.enable_submission_failure_alarm ? 1 : 0

  alarm_name          = "${var.org_name}-cnam-submission-failure-${terraform.workspace}"
  alarm_description   = "PRD-17 CNAM submission failures detected."
  namespace           = local.metric_namespace
  metric_name         = "CNAMSubmissionFailure"
  statistic           = "Sum"
  period              = 600
  evaluation_periods  = 1
  threshold           = 3
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = var.alarm_action_arns
  ok_actions          = var.alarm_action_arns

  tags = local.common_tags
}

resource "aws_cloudwatch_metric_alarm" "drift_detected" {
  count = var.enable_drift_alarm ? 1 : 0

  alarm_name          = "${var.org_name}-cnam-drift-detected-${terraform.workspace}"
  alarm_description   = "PRD-17 CNAM drift detected between desired and verified state."
  namespace           = local.metric_namespace
  metric_name         = "CNAMDriftDetected"
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

