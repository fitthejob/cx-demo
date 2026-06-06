resource "aws_cloudtrail" "main" {
  name                          = "${var.org_name}-platform-trail"
  s3_bucket_name                = aws_s3_bucket.audit.bucket
  s3_key_prefix                 = "cloudtrail"
  include_global_service_events = true
  is_multi_region_trail         = true
  enable_log_file_validation    = true
  kms_key_id                    = local.env_kms_key_arn
  sns_topic_name                = aws_sns_topic.cloudtrail.arn
  cloud_watch_logs_group_arn    = "${aws_cloudwatch_log_group.cloudtrail.arn}:*"
  cloud_watch_logs_role_arn     = aws_iam_role.cloudtrail_cloudwatch.arn

  event_selector {
    read_write_type           = "All"
    include_management_events = true

    data_resource {
      type   = "AWS::S3::Object"
      values = [
        "${data.terraform_remote_state.bootstrap.outputs.state_bucket_arn}/",
        "${aws_s3_bucket.audit.arn}/"
      ]
    }

    data_resource {
      type   = "AWS::Lambda::Function"
      values = ["arn:aws:lambda"]
    }
  }

  depends_on = [
    aws_s3_bucket_policy.audit,
    aws_sns_topic_policy.cloudtrail
  ]

  tags = {
    Layer = "L0"
    PRD   = "PRD-03"
  }
}

resource "aws_cloudwatch_log_group" "cloudtrail" {
  name              = "/aws/cloudtrail/${var.org_name}-platform-trail"
  retention_in_days = 365
  kms_key_id        = local.env_kms_key_arn
}

resource "aws_sns_topic" "cloudtrail" {
  name              = "${var.org_name}-cloudtrail-notifications"
  kms_master_key_id = local.env_kms_key_arn
}

resource "aws_sns_topic_policy" "cloudtrail" {
  arn = aws_sns_topic.cloudtrail.arn

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AllowCloudTrailPublish"
        Effect    = "Allow"
        Principal = { Service = "cloudtrail.amazonaws.com" }
        Action    = "sns:Publish"
        Resource  = aws_sns_topic.cloudtrail.arn
      }
    ]
  })
}
