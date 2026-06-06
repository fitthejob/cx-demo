resource "aws_connect_instance" "main" {
  identity_management_type = var.identity_management_type
  inbound_calls_enabled    = true
  outbound_calls_enabled   = true
  early_media_enabled      = true

  auto_resolve_best_voices_enabled = true
  contact_flow_logs_enabled        = true
  contact_lens_enabled             = true
  multi_party_conference_enabled   = false # Enable in PRD-54 when transfer service is configured

  instance_alias = "${var.org_name}-${terraform.workspace}"

  timeouts {
    create = "5m"
    delete = "5m"
  }

  lifecycle {
    prevent_destroy = true

    # FR-008: Cross-validate identity management type against SSO layer enablement
    precondition {
      condition     = var.identity_management_type == "CONNECT_MANAGED" || var.sso_integration_enabled
      error_message = "identity_management_type SAML or EXISTING_DIRECTORY requires sso_integration_enabled = true. Enable the PRD-120 SSO capability pack or use CONNECT_MANAGED."
    }
  }

  # Note: aws_connect_instance does not support the tags argument.
  # Tags are applied via the default_tags provider block.
}

resource "aws_connect_security_profile" "platform_admin" {
  instance_id = aws_connect_instance.main.id
  name        = "Platform-Admin"
  description = "Full administrative access for platform engineer. Assigned to named users only."

  permissions = [
    "BasicAgentAccess",
    "OutboundCallAccess",
    "VideoContact.Access",
    "RealtimeContactLens.View",
    "GraphTrends.View",
    "AccessMetrics",
    "AccessMetrics.HistoricalMetrics.Access",
    "AccessMetrics.RealTimeMetrics.Access",
    "AgentStates.Edit",
    "AgentStates.View",
    "AgentGrouping.View",
    "AgentGrouping.Edit",
    "PhoneNumbers.View",
    "PhoneNumbers.Edit",
    "Queues.Edit",
    "Queues.View",
    "RoutingPolicies.Edit",
    "RoutingPolicies.View",
    "SecurityProfiles.Edit",
    "SecurityProfiles.View",
    "Users.Edit",
    "Users.View",
    "ContactFlows.Edit",
    "ContactFlows.View",
    "ContactFlowModules.Edit",
    "ContactFlowModules.View",
    "HoursOfOperation.Edit",
    "HoursOfOperation.View",
    "Prompts.Edit",
    "Prompts.View",
    "TransferDestinations.Edit",
    "TransferDestinations.View",
    "Bots.Edit",
    "Bots.View",
  ]

  tags = { Layer = "L1", PRD = "PRD-10" }
}

resource "aws_connect_security_profile" "agent_default" {
  instance_id = aws_connect_instance.main.id
  name        = "Agent-Default"
  description = "Standard agent permissions. Assigned to all agents provisioned in PRD-50."

  permissions = [
    "BasicAgentAccess",
    "OutboundCallAccess",
    "RealtimeContactLens.View",
  ]

  tags = { Layer = "L1", PRD = "PRD-10" }
}

# Kinesis Data Stream and CTR storage association are deferred to PRD-20.
# Connect retains CTRs natively for 24 months. The stream can be added to
# an existing instance at any time via aws_connect_instance_storage_config.
