resource "aws_cloudwatch_log_group" "contact_flow_logs" {
  name              = "/aws/connect/${aws_connect_instance.main.id}"
  retention_in_days = 365
  kms_key_id        = local.env_kms_key_arn

  tags = {
    Layer = "L1"
    PRD   = "PRD-10"
  }
}

resource "aws_cloudwatch_metric_alarm" "concurrent_call_breach" {
  alarm_name          = "${var.org_name}-connect-concurrent-call-breach-${terraform.workspace}"
  alarm_description   = "ALARM-10-01: Callers being rejected — concurrent call limit breached"
  namespace           = "AWS/Connect"
  metric_name         = "CallsBreachingConcurrencyQuota"
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.alarm_action_arns

  dimensions = {
    InstanceId  = aws_connect_instance.main.id
    MetricGroup = "VoiceCalls"
  }

  tags = { Layer = "L1", PRD = "PRD-10" }
}

resource "aws_cloudwatch_metric_alarm" "contact_flow_fatal" {
  alarm_name          = "${var.org_name}-connect-flow-fatal-${terraform.workspace}"
  alarm_description   = "ALARM-10-02: Contact flow fatal error — callers experiencing broken flows"
  namespace           = "AWS/Connect"
  metric_name         = "ContactFlowFatalErrors"
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.alarm_action_arns

  dimensions = {
    InstanceId  = aws_connect_instance.main.id
    MetricGroup = "ContactFlow"
  }

  tags = { Layer = "L1", PRD = "PRD-10" }
}

resource "aws_cloudwatch_metric_alarm" "recording_upload_failure" {
  alarm_name          = "${var.org_name}-connect-recording-failure-${terraform.workspace}"
  alarm_description   = "ALARM-10-03: Call recording upload failure — compliance obligations at risk"
  namespace           = "AWS/Connect"
  metric_name         = "CallRecordingUploadError"
  statistic           = "Sum"
  period              = 900
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.alarm_action_arns

  dimensions = {
    InstanceId  = aws_connect_instance.main.id
    MetricGroup = "CallRecordings"
  }

  tags = { Layer = "L1", PRD = "PRD-10" }
}
