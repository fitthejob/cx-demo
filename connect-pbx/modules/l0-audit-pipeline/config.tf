resource "aws_config_configuration_recorder" "main" {
  name     = "${var.org_name}-platform-recorder"
  role_arn = aws_iam_role.config_service.arn

  recording_group {
    all_supported                 = true
    include_global_resource_types = true
  }
}

resource "aws_config_delivery_channel" "main" {
  name           = "${var.org_name}-platform-channel"
  s3_bucket_name = aws_s3_bucket.audit.bucket
  s3_key_prefix  = "config"
  s3_kms_key_arn = local.env_kms_key_arn
  sns_topic_arn  = aws_sns_topic.config.arn

  snapshot_delivery_properties {
    delivery_frequency = "TwentyFour_Hours"
  }

  depends_on = [
    aws_config_configuration_recorder.main,
    aws_iam_role.config_service,
    aws_s3_bucket_policy.audit
  ]
}

resource "aws_config_configuration_recorder_status" "main" {
  name       = aws_config_configuration_recorder.main.name
  is_enabled = true
  depends_on = [aws_config_delivery_channel.main]
}

resource "aws_sns_topic" "config" {
  name              = "${var.org_name}-config-notifications"
  kms_master_key_id = local.env_kms_key_arn
}

resource "aws_sns_topic_policy" "config" {
  arn = aws_sns_topic.config.arn

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AllowConfigPublish"
        Effect    = "Allow"
        Principal = { Service = "config.amazonaws.com" }
        Action    = "sns:Publish"
        Resource  = aws_sns_topic.config.arn
        Condition = {
          StringEquals = {
            "AWS:SourceAccount" = data.aws_caller_identity.current.account_id
          }
        }
      }
    ]
  })
}
