data "archive_file" "phone_association" {
  type        = "zip"
  source_dir  = "${path.module}/lambda/phone-association"
  output_path = "${path.module}/.build/phone-association.zip"
}

#checkov:skip=CKV_AWS_116: Phone-association is invoked synchronously by operator tooling, so a DLQ does not apply to this execution model.
#checkov:skip=CKV_AWS_115: Reserved concurrency is intentionally left unset because admin-operation concurrency should be tuned per implementation.
#checkov:skip=CKV_AWS_117: This Lambda only calls the public Amazon Connect API and intentionally stays outside a VPC to avoid unnecessary network dependencies.
resource "aws_lambda_function" "phone_association" {
  function_name    = "${var.org_name}-phone-flow-association-${terraform.workspace}"
  description      = "Associates phone numbers with contact flows via the Connect API."
  runtime          = "python3.12"
  handler          = "phone_association.handler"
  role             = aws_iam_role.phone_association.arn
  filename         = data.archive_file.phone_association.output_path
  source_code_hash = data.archive_file.phone_association.output_base64sha256
  timeout          = 30
  memory_size      = 128
  kms_key_arn      = local.env_kms_key_arn

  tracing_config {
    mode = "Active"
  }

  environment {
    variables = {
      CONNECT_INSTANCE_ID = local.connect_instance_id
    }
  }

  tags = local.common_tags
}

resource "aws_cloudwatch_log_group" "phone_association" {
  name              = "/aws/lambda/${aws_lambda_function.phone_association.function_name}"
  retention_in_days = 365
  kms_key_id        = local.env_kms_key_arn

  tags = local.common_tags
}

resource "aws_iam_role" "phone_association" {
  name                 = "${var.org_name}-phone-flow-assoc-${terraform.workspace}"
  permissions_boundary = local.permission_boundary_arn

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })

  tags = local.common_tags
}

resource "aws_iam_role_policy" "phone_association" {
  name = "phone-flow-association"
  role = aws_iam_role.phone_association.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "connect:AssociatePhoneNumberContactFlow",
          "connect:DisassociatePhoneNumberContactFlow"
        ]
        Resource = [
          "arn:aws:connect:${var.aws_region}:*:instance/${local.connect_instance_id}",
          "arn:aws:connect:${var.aws_region}:*:phone-number/*",
          "arn:aws:connect:${var.aws_region}:*:instance/${local.connect_instance_id}/contact-flow/*"
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "${aws_cloudwatch_log_group.phone_association.arn}:*"
      }
    ]
  })
}

resource "terraform_data" "phone_number_flow_associations" {
  for_each = var.number_flow_associations

  triggers_replace = {
    association_key    = each.key
    function_name      = aws_lambda_function.phone_association.function_name
    phone_number_id    = local.phone_number_ids[each.key]
    contact_flow_id    = local.contact_flow_id_map[each.value]
    environment        = terraform.workspace
    python_executable  = var.python_executable
    helper_script_path = "${path.module}/scripts/invoke_phone_association.py"
    destroy_output_path = "${path.module}/.build/phone-disassociation-${each.key}.json"
  }

  provisioner "local-exec" {
    command     = "${path.module}/scripts/invoke_phone_association.py"
    interpreter = [var.python_executable]

    environment = {
      FUNCTION_NAME   = aws_lambda_function.phone_association.function_name
      PHONE_NUMBER_ID = local.phone_number_ids[each.key]
      CONTACT_FLOW_ID = local.contact_flow_id_map[each.value]
      ACTION          = "associate"
      OUTPUT_PATH     = "${path.module}/.build/phone-association-${each.key}.json"
      RETRIES         = "3"
    }
  }

  provisioner "local-exec" {
    when    = destroy
    command = self.triggers_replace.helper_script_path
    interpreter = [
      self.triggers_replace.python_executable,
    ]

    environment = {
      FUNCTION_NAME   = self.triggers_replace.function_name
      PHONE_NUMBER_ID = self.triggers_replace.phone_number_id
      CONTACT_FLOW_ID = self.triggers_replace.contact_flow_id
      ACTION          = "disassociate"
      OUTPUT_PATH     = self.triggers_replace.destroy_output_path
      RETRIES         = "3"
    }
  }
}
