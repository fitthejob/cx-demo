resource "aws_dynamodb_table" "tfstate_lock" {
  name = "${var.org_name}-tfstate-lock"
  billing_mode = "PAY_PER_REQUEST"
  hash_key = "LockID"

  attribute {
    name = "LockID"
    type = "S"
  }

  server_side_encryption {
    enabled = true
    kms_key_arn = aws_kms_key.tfstate_bootstrap.arn
  }

  point_in_time_recovery {
    enabled = true

  }
  tags = {
    PRD = "PRD-00"
    Layer = "0"
    Usage = "state-locking"
  }
}