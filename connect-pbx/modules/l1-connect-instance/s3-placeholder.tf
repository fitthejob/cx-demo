resource "aws_s3_bucket" "recordings_placeholder" {
  bucket = "${var.org_name}-connect-recordings-placeholder-${data.aws_caller_identity.current.account_id}"

  tags = {
    Layer         = "L1"
    PRD           = "PRD-10"
    Superseded-By = "PRD-30"
    Purpose       = "Temporary call recording bucket. PRD-30 provisions the full storage architecture and updates this storage association."
  }
}

resource "aws_s3_bucket_versioning" "recordings_placeholder" {
  bucket = aws_s3_bucket.recordings_placeholder.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "recordings_placeholder" {
  bucket = aws_s3_bucket.recordings_placeholder.id

  rule {
    id     = "expire-placeholder-recordings"
    status = "Enabled"

    expiration {
      days = 30
    }

    noncurrent_version_expiration {
      noncurrent_days = 7
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }

    filter {}
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "recordings_placeholder" {
  bucket = aws_s3_bucket.recordings_placeholder.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = local.env_kms_key_arn
    }
  }
}

resource "aws_s3_bucket_public_access_block" "recordings_placeholder" {
  bucket                  = aws_s3_bucket.recordings_placeholder.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_policy" "recordings_placeholder_tls" {
  bucket = aws_s3_bucket.recordings_placeholder.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "DenyNonTLS"
      Effect    = "Deny"
      Principal = "*"
      Action    = "s3:*"
      Resource = [
        aws_s3_bucket.recordings_placeholder.arn,
        "${aws_s3_bucket.recordings_placeholder.arn}/*"
      ]
      Condition = {
        Bool = { "aws:SecureTransport" = "false" }
      }
    }]
  })
}

resource "aws_s3_bucket_logging" "recordings_placeholder" {
  count         = local.placeholder_access_log_bucket_name != null ? 1 : 0
  bucket        = aws_s3_bucket.recordings_placeholder.id
  target_bucket = local.placeholder_access_log_bucket_name
  target_prefix = "s3-access-logs/recordings-placeholder/"
}

resource "aws_connect_instance_storage_config" "call_recordings" {
  instance_id   = aws_connect_instance.main.id
  resource_type = "CALL_RECORDINGS"

  storage_config {
    s3_config {
      bucket_name   = aws_s3_bucket.recordings_placeholder.bucket
      bucket_prefix = "recordings"

      encryption_config {
        encryption_type = "KMS"
        key_id          = local.env_kms_key_arn
      }
    }
    storage_type = "S3"
  }
}
