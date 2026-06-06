provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Layer   = "L1"
      PRD     = "PRD-11"
      Project = var.org_name
    }
  }
}

data "terraform_remote_state" "connect_instance" {
  backend   = "s3"
  workspace = terraform.workspace
  config = {
    bucket = var.state_bucket
    key    = "l1-connect-instance/terraform.tfstate"
    region = var.aws_region
  }
}

locals {
  connect_instance_arn   = data.terraform_remote_state.connect_instance.outputs.connect_instance_arn
  module_path_normalized = replace(path.module, "\\", "/")

  common_tags = {
    Environment = terraform.workspace
    ManagedBy   = "terraform"
    OrgName     = var.org_name
    Layer       = "L1"
    PRD         = "PRD-11"
  }
}

data "external" "existing_phone_numbers" {
  for_each = var.phone_numbers

  program = [
    "python",
    "${local.module_path_normalized}/scripts/resolve_existing_phone_number.py",
  ]

  query = {
    number_key   = each.key
    aws_region   = var.aws_region
    target_arn   = local.connect_instance_arn
    phone_number = try(each.value.existing_phone_number, "")
  }
}

data "external" "available_phone_numbers" {
  for_each = local.claimable_phone_numbers

  program = [
    "python",
    "${local.module_path_normalized}/scripts/search_available_phone_numbers.py",
  ]

  query = {
    number_key          = each.key
    aws_region          = var.aws_region
    target_arn          = local.connect_instance_arn
    country_code        = each.value.country_code
    phone_number_type   = each.value.type
    phone_number_prefix = try(each.value.prefix, null) != null ? each.value.prefix : ""
  }
}

data "external" "phone_number_quota_headroom" {
  count = length(local.claimable_phone_numbers) > 0 ? 1 : 0

  program = [
    "python",
    "${local.module_path_normalized}/scripts/check_phone_number_quota.py",
  ]

  query = {
    aws_region            = var.aws_region
    target_arn            = local.connect_instance_arn
    requested_claim_count = tostring(length(local.claimable_phone_numbers))
  }
}

locals {
  reused_phone_numbers = {
    for key, value in data.external.existing_phone_numbers :
    key => value.result
    if try(value.result.exists, "false") == "true"
  }

  missing_existing_phone_numbers = {
    for key, value in var.phone_numbers :
    key => value
    if try(trimspace(value.existing_phone_number), "") != "" &&
      try(data.external.existing_phone_numbers[key].result.exists, "false") != "true"
  }

  claimable_phone_numbers = merge(
    {
      for key, value in var.phone_numbers :
      key => value
      if try(data.external.existing_phone_numbers[key].result.exists, "false") != "true" &&
        try(trimspace(value.existing_phone_number), "") == ""
    },
    {
      for key, value in local.missing_existing_phone_numbers :
      key => value
      if try(value.claim_if_missing, true)
    }
  )

  unresolved_existing_phone_numbers = [
    for key, value in local.missing_existing_phone_numbers :
    "${key} (${value.existing_phone_number})"
    if !try(value.claim_if_missing, true)
  ]

  unavailable_claimable_phone_number_messages = [
    for key, value in local.claimable_phone_numbers :
    try(
      data.external.available_phone_numbers[key].result.message,
      "Amazon Connect phone number preflight failed for '${key}' before claim attempt."
    )
    if try(data.external.available_phone_numbers[key].result.available, "false") != "true"
  ]

  phone_number_quota_headroom_messages = (
    length(local.claimable_phone_numbers) > 0 &&
    try(data.external.phone_number_quota_headroom[0].result.allowed, "false") != "true"
    ) ? [
    try(
      data.external.phone_number_quota_headroom[0].result.message,
      "Amazon Connect phone number quota preflight failed before claim attempt."
    )
  ] : []
}

resource "terraform_data" "validate_phone_number_resolution" {
  input = {
    unresolved_existing_phone_numbers = local.unresolved_existing_phone_numbers
  }

  lifecycle {
    precondition {
      condition     = length(local.unresolved_existing_phone_numbers) == 0
      error_message = "existing_phone_number was requested but not found in the target Connect instance for: ${join(", ", local.unresolved_existing_phone_numbers)}"
    }
  }
}

resource "terraform_data" "validate_phone_number_availability" {
  input = {
    unavailable_claimable_phone_number_messages = local.unavailable_claimable_phone_number_messages
  }

  lifecycle {
    precondition {
      condition     = length(local.unavailable_claimable_phone_number_messages) == 0
      error_message = "Phone number availability preflight failed before claim:\n- ${join("\n- ", local.unavailable_claimable_phone_number_messages)}"
    }
  }
}

resource "terraform_data" "validate_phone_number_quota_headroom" {
  input = {
    phone_number_quota_headroom_messages = local.phone_number_quota_headroom_messages
  }

  lifecycle {
    precondition {
      condition     = length(local.phone_number_quota_headroom_messages) == 0
      error_message = "Phone number quota preflight failed before claim:\n- ${join("\n- ", local.phone_number_quota_headroom_messages)}"
    }
  }
}

resource "aws_connect_phone_number" "inventory" {
  for_each = var.phone_numbers

  target_arn   = local.connect_instance_arn
  country_code = each.value.country_code
  type         = each.value.type
  description  = each.value.description
  prefix       = each.value.prefix

  tags = merge(local.common_tags, {
    NumberKey  = each.key
    Purpose    = each.value.purpose
    CostCenter = each.value.cost_center
  })

  depends_on = [
    terraform_data.validate_phone_number_resolution,
    terraform_data.validate_phone_number_availability,
    terraform_data.validate_phone_number_quota_headroom,
  ]

  lifecycle {
    prevent_destroy = true
  }
}

import {
  for_each = {
    for key, value in data.external.existing_phone_numbers :
    key => value.result.phone_number_id
    if try(value.result.exists, "false") == "true"
  }

  to = aws_connect_phone_number.inventory[each.key]
  id = each.value
}
