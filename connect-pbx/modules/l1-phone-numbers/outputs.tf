locals {
  claimed_phone_number_arns = {
    for key, value in aws_connect_phone_number.inventory :
    key => value.arn
  }

  reused_phone_number_arns = {
    for key, value in local.reused_phone_numbers :
    key => value.phone_number_arn
  }

  claimed_phone_number_ids = {
    for key, value in aws_connect_phone_number.inventory :
    key => value.id
  }

  reused_phone_number_ids = {
    for key, value in local.reused_phone_numbers :
    key => value.phone_number_id
  }

  claimed_phone_number_inventory = {
    for key, value in aws_connect_phone_number.inventory :
    key => {
      phone_number     = value.phone_number
      arn              = value.arn
      id               = value.id
      type             = value.type
      country_code     = value.country_code
      prefix_requested = var.phone_numbers[key].prefix
      description      = value.description
      purpose          = var.phone_numbers[key].purpose
      cost_center      = var.phone_numbers[key].cost_center
      cnam_name        = try(var.phone_numbers[key].cnam_name, null)
      source           = "claimed"
    }
  }

  reused_phone_number_inventory = {
    for key, value in local.reused_phone_numbers :
    key => {
      phone_number     = value.phone_number
      arn              = value.phone_number_arn
      id               = value.phone_number_id
      type             = value.phone_number_type
      country_code     = value.country_code
      prefix_requested = var.phone_numbers[key].prefix
      description      = length(trimspace(try(value.phone_number_description, ""))) > 0 ? value.phone_number_description : var.phone_numbers[key].description
      purpose          = var.phone_numbers[key].purpose
      cost_center      = var.phone_numbers[key].cost_center
      cnam_name        = try(var.phone_numbers[key].cnam_name, null)
      source           = "existing"
    }
  }
}

output "phone_number_arns" {
  description = "Map of number key to phone number ARN. Includes both reused existing numbers and newly claimed numbers."
  value       = merge(local.claimed_phone_number_arns, local.reused_phone_number_arns)
}

output "phone_number_ids" {
  description = "Map of number key to phone number ID. Includes both reused existing numbers and newly claimed numbers."
  value       = merge(local.claimed_phone_number_ids, local.reused_phone_number_ids)
}

output "phone_number_inventory" {
  description = "Full number inventory including actual E.164 number, ARN, type, country, prefix requested, and whether the number was reused or newly claimed."
  value       = merge(local.claimed_phone_number_inventory, local.reused_phone_number_inventory)
}
