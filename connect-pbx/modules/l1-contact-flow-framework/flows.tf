resource "aws_connect_contact_flow" "main_inbound" {
  instance_id = local.connect_instance_id
  name        = "${var.org_name}-Main-Inbound"
  description = "Primary inbound flow with hours gating, closure checks, menu routing, and queue transfer."
  type        = "CONTACT_FLOW"

  content = templatefile("${path.module}/flows/main-inbound.json.tftpl", {
    hours_of_operation_id    = local.hours_of_operation_ids["standard-business"]
    queue_sales_arn          = local.queue_arns["sales"]
    queue_support_arn        = local.queue_arns["customer-support"]
    queue_billing_arn        = local.queue_arns["billing"]
    queue_tech_arn           = local.queue_arns["technical-support"]
    queue_general_arn        = local.queue_arns["general"]
    after_hours_flow_id      = aws_connect_contact_flow.after_hours.arn
    error_handler_flow_id    = aws_connect_contact_flow.error_handler.arn
    closure_check_lambda_arn = aws_lambda_function.closure_check.arn
    prompt_greeting          = var.flow_prompts["greeting"]
    prompt_menu              = var.flow_prompts["main_menu"]
  })

  tags = merge(local.common_tags, {
    FlowType = "main-inbound"
  })
}

resource "aws_connect_contact_flow" "after_hours" {
  instance_id = local.connect_instance_id
  name        = "${var.org_name}-After-Hours"
  description = "After-hours handling with callback or voicemail fallback messaging."
  type        = "CONTACT_FLOW"

  content = templatefile("${path.module}/flows/after-hours-module.json.tftpl", {
    prompt_after_hours           = var.flow_prompts["after_hours"]
    prompt_callback_offer        = var.flow_prompts["callback_offer"]
    prompt_voicemail_unavailable = var.flow_prompts["voicemail_unavailable"]
    prompt_goodbye               = var.flow_prompts["goodbye"]
  })

  tags = merge(local.common_tags, {
    FlowType = "after-hours"
  })
}

resource "aws_connect_contact_flow" "error_handler" {
  instance_id = local.connect_instance_id
  name        = "${var.org_name}-Error-Handler"
  description = "Global error handler. Plays an apology and disconnects cleanly."
  type        = "CONTACT_FLOW"

  content = templatefile("${path.module}/flows/error-handler.json.tftpl", {
    prompt_error   = var.flow_prompts["error"]
    prompt_goodbye = var.flow_prompts["goodbye"]
  })

  tags = merge(local.common_tags, {
    FlowType = "error-handler"
  })
}

resource "aws_connect_contact_flow" "queue_transfer" {
  instance_id = local.connect_instance_id
  name        = "${var.org_name}-Queue-Transfer"
  description = "Reusable queue-transfer flow. Expects target_queue_arn and overflow_action contact attributes."
  type        = "QUEUE_TRANSFER"

  content = templatefile("${path.module}/flows/queue-transfer-module.json.tftpl", {
    prompt_queue_wait           = var.flow_prompts["queue_wait"]
    prompt_overflow             = var.flow_prompts["overflow"]
    prompt_voicemail_unavailable = var.flow_prompts["voicemail_unavailable"]
    prompt_goodbye              = var.flow_prompts["goodbye"]
  })

  tags = merge(local.common_tags, {
    FlowType = "queue-transfer"
  })
}
