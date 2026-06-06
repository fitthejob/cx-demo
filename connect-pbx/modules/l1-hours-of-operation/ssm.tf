resource "aws_ssm_parameter" "emergency_closure" {
  name   = "/${var.org_name}/${terraform.workspace}/emergency-closure"
  type   = "SecureString"
  key_id = local.env_kms_key_arn
  value = jsonencode({
    active     = false
    message    = ""
    updated_by = ""
    updated_at = ""
  })

  tags = local.common_tags

  lifecycle {
    ignore_changes = [value]
  }
}
