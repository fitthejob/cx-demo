resource "aws_cloudwatch_metric_alarm" "portability_lambda_errors" {
  alarm_name          = "${var.org_name}-number-portability-check-errors-${terraform.workspace}"
  alarm_description   = "PRD-15 portability check Lambda errors indicate eligibility checks are failing."
  namespace           = "AWS/Lambda"
  metric_name         = "Errors"
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 3
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"

  dimensions = {
    FunctionName = aws_lambda_function.portability_check.function_name
  }

  alarm_actions = [local.platform_alert_topic_arn]
  ok_actions    = [local.platform_alert_topic_arn]

  tags = local.common_tags
}
