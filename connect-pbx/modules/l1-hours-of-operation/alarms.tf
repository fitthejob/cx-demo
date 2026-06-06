# ALARM-12-02: Daily Holiday Check Lambda Failure
# Fires when the holiday check Lambda reports >= 1 error in a 24-hour period.
# Since the Lambda runs once daily, any failure means today's closure status
# was not computed. Federal holidays will be missed until Lambda recovers.

resource "aws_cloudwatch_metric_alarm" "holiday_check_errors" {
  alarm_name          = "${var.org_name}-holiday-check-errors-${terraform.workspace}"
  alarm_description   = "ALARM-12-02: Holiday check Lambda failure — closure status not computed today."
  namespace           = "AWS/Lambda"
  metric_name         = "Errors"
  statistic           = "Sum"
  period              = 86400
  evaluation_periods  = 1
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"

  dimensions = {
    FunctionName = aws_lambda_function.holiday_check.function_name
  }

  alarm_actions = var.alarm_action_arns
  ok_actions    = var.alarm_action_arns

  tags = local.common_tags
}

# ALARM-12-03: Emergency Closure Left Active
# Fires when the emergency closure SSM parameter has been active=true for
# more than 24 hours. Uses a custom CloudWatch metric published by the
# holiday check Lambda on each invocation.

resource "aws_cloudwatch_metric_alarm" "emergency_closure_stale" {
  alarm_name          = "${var.org_name}-emergency-closure-stale-${terraform.workspace}"
  alarm_description   = "ALARM-12-03: Emergency closure active for >24h — is this intentional?"
  namespace           = "${var.org_name}/HolidayCheck"
  metric_name         = "EmergencyClosureActiveHours"
  statistic           = "Maximum"
  period              = 86400
  evaluation_periods  = 1
  threshold           = 24
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"

  dimensions = {
    Environment = terraform.workspace
  }

  alarm_actions = var.alarm_action_arns
  ok_actions    = var.alarm_action_arns

  tags = local.common_tags
}
