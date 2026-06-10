resource "aws_dynamodb_table" "holiday_closures" {
  name             = "${var.org_name}-holiday-closures-${terraform.workspace}"
  billing_mode     = "PAY_PER_REQUEST"
  hash_key         = "date"
  stream_enabled   = true
  stream_view_type = "NEW_IMAGE"

  attribute {
    name = "date"
    type = "S"
  }

  server_side_encryption {
    enabled    = true
    kms_key_arn = local.env_kms_key_arn
  }

  point_in_time_recovery {
    enabled = true
  }

  tags = local.common_tags
}

resource "aws_dynamodb_table_item" "holidays" {
  for_each = { for h in var.holiday_closures : h.date => h }

  table_name = aws_dynamodb_table.holiday_closures.name
  hash_key   = "date"

  item = jsonencode({
    date          = { S = each.value.date }
    name          = { S = each.value.name }
    schedule_keys = { SS = each.value.schedule_keys }
  })
}

resource "aws_dynamodb_table" "daily_closure_status" {
  name         = "${var.org_name}-daily-closure-status-${terraform.workspace}"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "id"

  attribute {
    name = "id"
    type = "S"
  }

  server_side_encryption {
    enabled    = true
    kms_key_arn = local.env_kms_key_arn
  }

  point_in_time_recovery {
    enabled = true
  }

  tags = local.common_tags
}
