resource "aws_cloudwatch_metric_alarm" "high_spam_inventory" {
  count = var.enable_high_spam_alarm ? 1 : 0

  alarm_name          = "${var.org_name}-high-spam-risk-inventory-${terraform.workspace}"
  alarm_description   = "PRD-16 high spam risk numbers detected in current inventory."
  namespace           = local.metric_namespace
  metric_name         = "NumbersWithHighSpamRisk"
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

resource "aws_cloudwatch_metric_alarm" "attestation_degraded" {
  count = var.enable_attestation_alarm ? 1 : 0

  alarm_name          = "${var.org_name}-stir-shaken-attestation-degraded-${terraform.workspace}"
  alarm_description   = "PRD-16 degraded STIR/SHAKEN attestation signals detected."
  namespace           = local.metric_namespace
  metric_name         = "STIRSHAKENAttestationDegraded"
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

