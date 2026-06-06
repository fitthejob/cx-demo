# cloudwatch.tf — ALARM-14-02: IVR No Input Spike
#
# Note: ALARM-14-01 (ContactFlowFatalErrors) is already provisioned by
# PRD-10 (l1-connect-instance/cloudwatch.tf) and is NOT duplicated here.

resource "aws_cloudwatch_log_metric_filter" "ivr_no_input" {
  name           = "${var.org_name}-ivr-no-input-${terraform.workspace}"
  log_group_name = local.contact_flow_log_group_name
  pattern        = "{ $.ContactFlowModuleType = \"GetParticipantInput\" && $.Results = \"InputTimeLimitExceeded\" }"

  metric_transformation {
    name          = "IVRNoInputCount"
    namespace     = "${var.org_name}/Connect"
    value         = "1"
    default_value = "0"
  }
}

resource "aws_cloudwatch_metric_alarm" "ivr_no_input_spike" {
  alarm_name          = "${var.org_name}-ivr-no-input-spike-${terraform.workspace}"
  alarm_description   = "ALARM-14-02: IVR no-input rate exceeds threshold — callers not engaging with menu (prompt clarity issue)"
  namespace           = "${var.org_name}/Connect"
  metric_name         = "IVRNoInputCount"
  statistic           = "Sum"
  period              = 900
  evaluation_periods  = 1
  threshold           = 10
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.alarm_action_arns

  tags = local.common_tags
}
