#--------------------
# tfstate bucket
#--------------------

resource "aws_s3_bucket" "tfstate" {
  bucket = "${var.org_name}-tfstate-${data.aws_caller_identity.current.account_id}"

  # prevents accidental 'terraform destroy' from deleting the state
  lifecycle {
    prevent_destroy = true
  }
  tags = {
    PRD   = "PRD-00"
    Layer = "0"
  }
}

resource "aws_s3_bucket_versioning" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  rule {
    apply_server_side_encryption_by_default {
      kms_master_key_id = aws_kms_alias.tfstate_bootstrap.arn
      sse_algorithm     = "aws:kms"
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_policy" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id
  policy = jsonencode(
    {
      Version = "2012-10-17"
      Statement = [
        {
          Sid       = "EnforceTLS"
          Effect    = "Deny"
          Principal = "*"
          Action    = "s3:*"
          Resource = [
            aws_s3_bucket.tfstate.arn,
            "${aws_s3_bucket.tfstate.arn}/*"
          ]
          Condition = {
            Bool = { "aws:SecureTransport" = "false" }
          }
        },
        {
          Sid       = "DenyNonKMSEncryption"
          Effect    = "Deny"
          Principal = "*"
          Action    = "s3:PutObject"
          Resource  = "${aws_s3_bucket.tfstate.arn}/*"
          Condition = {
            StringNotEquals = { "s3:x-amz-server-side-encryption" = "aws:kms" }
          }

        }
      ]
    }

  )
}

resource "aws_s3_bucket_logging" "tfstate" {
  bucket        = aws_s3_bucket.tfstate.id
  target_bucket = aws_s3_bucket.tfstate_logs.id
  target_prefix = "logs/tfstate/"
}

#--------------------
# tfstate logs bucket
#--------------------

resource "aws_s3_bucket" "tfstate_logs" {
  bucket = "${var.org_name}-tfstate-logs-${data.aws_caller_identity.current.account_id}"
  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "tfstate_logs" {
  bucket = aws_s3_bucket.tfstate_logs.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_policy" "tfstate_logs" {
  bucket = aws_s3_bucket.tfstate_logs.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AllowS3LogDelivery"
        Effect    = "Allow"
        Principal = { Service = "logging.s3.amazonaws.com" }
        Action    = "s3:PutObject"
        Resource  = "${aws_s3_bucket.tfstate_logs.arn}/*"
        Condition = {
          StringEquals = { "aws:SourceAccount" = data.aws_caller_identity.current.account_id }
        }
      },
      {
        Sid       = "EnforceTLS"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource = [
          aws_s3_bucket.tfstate_logs.arn,
          "${aws_s3_bucket.tfstate_logs.arn}/*"
        ]
        Condition = {
          Bool = { "aws:SecureTransport" = "false" }
        }
      }
    ]
  })

}

resource "aws_s3_bucket_public_access_block" "tfstate_logs" {
  bucket                  = aws_s3_bucket.tfstate_logs.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "tfstate_logs" {
  bucket = aws_s3_bucket.tfstate_logs.id
  rule {
    id     = "log_retention"
    status = "Enabled"

    # permanently delete logs after 365 days
    expiration {
      days = 90
    }

    # clean up failed/incomplete multi-part uploads for cost-efficiency
    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}
