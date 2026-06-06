resource "aws_sns_topic" "platform_alerts" {
  name              = "${var.org_name}-platform-alerts"
  kms_master_key_id = local.env_kms_key_arn

  tags = {
    Layer = "L0"
    PRD   = "PRD-03"
    Name  = "Platform-wide alert topic - all alarms publish here"
  }
}

resource "aws_sns_topic_policy" "platform_alerts" {
  arn = aws_sns_topic.platform_alerts.arn

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AllowLambdaPublish"
        Effect    = "Allow"
        Principal = { Service = "lambda.amazonaws.com" }
        Action    = "sns:Publish"
        Resource  = aws_sns_topic.platform_alerts.arn
      },
      {
        Sid       = "AllowCloudWatchAlarms"
        Effect    = "Allow"
        Principal = { Service = "cloudwatch.amazonaws.com" }
        Action    = "sns:Publish"
        Resource  = aws_sns_topic.platform_alerts.arn
      },
      {
        Sid       = "AllowEventBridge"
        Effect    = "Allow"
        Principal = { Service = "events.amazonaws.com" }
        Action    = "sns:Publish"
        Resource  = aws_sns_topic.platform_alerts.arn
      }
    ]
  })
}
