# kms.tf - bootstrap key only

resource "aws_kms_key" "tfstate_bootstrap" {
  description             = "Terraform state encryption - bootstrap module only"
  deletion_window_in_days = 14
  enable_key_rotation     = true

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "RootAccess"
        Effect    = "Allow"
        Principal = { AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root" }
        Action    = "kms:*"
        Resource  = "*"
      },
      {
        Sid       = "TerraformExecutionAccess"
        Effect    = "Allow"
        Principal = { AWS = aws_iam_role.terraform_execution.arn }
        Action    = ["kms:Decrypt", "kms:GenerateDataKey", "kms:DescribeKey"]
        Resource  = "*"
      }
    ]
    }
  )
  tags = { PRD = "PRD-00", Scope = "bootstrap-only" }
}

resource "aws_kms_alias" "tfstate_bootstrap" {
  name          = "alias/${var.org_name}-tfstate-bootstrap"
  target_key_id = aws_kms_key.tfstate_bootstrap.key_id
}
