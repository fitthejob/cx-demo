resource "aws_cloudwatch_event_rule" "access_analyzer_findings" {
  name        = "${var.org_name}-access-analyzer-findings"
  description = "Routes active external access findings from IAM Access Analyzer to platform alerts"

  event_pattern = jsonencode({
    source      = ["aws.access-analyzer"]
    detail-type = ["Access Analyzer Finding"]
    detail = {
      status      = ["ACTIVE"]
      findingType = ["ExternalAccess"]
    }
  })
}

resource "aws_cloudwatch_event_target" "access_analyzer_findings" {
  rule      = aws_cloudwatch_event_rule.access_analyzer_findings.name
  target_id = "platform-alerts-sns"
  arn       = aws_sns_topic.platform_alerts.arn
}
