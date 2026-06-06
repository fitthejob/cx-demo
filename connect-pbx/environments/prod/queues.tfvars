# Production baseline mirrors dev until business-specific routing is finalized.

enable_audit_integration = true

queues = {

  general = {
    enabled                = true
    name                   = "General-Inbound"
    description            = "Main inbound queue for calls not matching a specific department"
    hours_of_operation_key = "standard-business"
    routing_strategy       = "LONGEST_IDLE"
    max_contacts           = 0
    max_wait_minutes       = 10
    overflow_action        = "VOICEMAIL"
    cost_center            = "operations"
    priority               = 3
  }

  sales = {
    enabled                = true
    name                   = "Sales"
    description            = "Sales team inbound queue"
    hours_of_operation_key = "standard-business"
    routing_strategy       = "LEAST_OCCUPIED"
    max_contacts           = 0
    max_wait_minutes       = 10
    overflow_action        = "VOICEMAIL"
    cost_center            = "sales"
    priority               = 2
  }

  customer-support = {
    enabled                = true
    name                   = "Customer-Support"
    description            = "Customer support inbound queue"
    hours_of_operation_key = "standard-business"
    routing_strategy       = "LONGEST_IDLE"
    max_contacts           = 0
    max_wait_minutes       = 10
    overflow_action        = "VOICEMAIL"
    cost_center            = "support"
    priority               = 2
  }

  billing = {
    enabled                = true
    name                   = "Billing"
    description            = "Billing and accounts inbound queue"
    hours_of_operation_key = "standard-business"
    routing_strategy       = "LONGEST_IDLE"
    max_contacts           = 0
    max_wait_minutes       = 10
    overflow_action        = "VOICEMAIL"
    cost_center            = "billing"
    priority               = 2
  }

  technical-support = {
    enabled                = true
    name                   = "Technical-Support"
    description            = "Technical support inbound queue — extended hours"
    hours_of_operation_key = "extended"
    routing_strategy       = "LEAST_OCCUPIED"
    max_contacts           = 0
    max_wait_minutes       = 15
    overflow_action        = "VOICEMAIL"
    cost_center            = "tech-support"
    priority               = 2
  }

  escalations = {
    enabled                = true
    name                   = "Escalations-Tier2"
    description            = "Escalation queue for Tier 2 issues. Highest priority routing."
    hours_of_operation_key = "standard-business"
    routing_strategy       = "LEAST_OCCUPIED"
    max_contacts           = 0
    max_wait_minutes       = 5
    overflow_action        = "CALLBACK"
    cost_center            = "support"
    priority               = 1
  }

  system = {
    enabled                = true
    name                   = "System-Internal"
    description            = "Reserved system queue for transfers, voicemail callbacks, and outbound. Not exposed to inbound callers."
    hours_of_operation_key = "twenty-four-seven"
    routing_strategy       = "LEAST_OCCUPIED"
    max_contacts           = 0
    max_wait_minutes       = 0
    overflow_action        = "DISCONNECT"
    cost_center            = "operations"
    priority               = 5
  }

}

routing_profiles = {

  sales-primary = {
    name                       = "Sales-Primary"
    description                = "Primary profile for Sales agents. Overflow to General after 2 minutes."
    default_outbound_queue_key = "sales"
    media_concurrencies = [
      { channel = "VOICE", concurrency = 1 }
    ]
    queue_configs = [
      { queue_key = "sales", channel = "VOICE", priority = 1, delay_seconds = 0 },
      { queue_key = "general", channel = "VOICE", priority = 2, delay_seconds = 120 }
    ]
  }

  support-primary = {
    name                       = "Support-Primary"
    description                = "Primary profile for Customer Support agents. Overflow to Tech Support then General."
    default_outbound_queue_key = "customer-support"
    media_concurrencies = [
      { channel = "VOICE", concurrency = 1 }
    ]
    queue_configs = [
      { queue_key = "customer-support", channel = "VOICE", priority = 1, delay_seconds = 0 },
      { queue_key = "technical-support", channel = "VOICE", priority = 2, delay_seconds = 120 },
      { queue_key = "general", channel = "VOICE", priority = 3, delay_seconds = 300 }
    ]
  }

  billing-primary = {
    name                       = "Billing-Primary"
    description                = "Primary profile for Billing agents. Overflow to Customer Support then General."
    default_outbound_queue_key = "billing"
    media_concurrencies = [
      { channel = "VOICE", concurrency = 1 }
    ]
    queue_configs = [
      { queue_key = "billing", channel = "VOICE", priority = 1, delay_seconds = 0 },
      { queue_key = "customer-support", channel = "VOICE", priority = 2, delay_seconds = 120 },
      { queue_key = "general", channel = "VOICE", priority = 3, delay_seconds = 300 }
    ]
  }

  tech-support-primary = {
    name                       = "TechSupport-Primary"
    description                = "Primary profile for Technical Support agents. Overflow to Customer Support then General."
    default_outbound_queue_key = "technical-support"
    media_concurrencies = [
      { channel = "VOICE", concurrency = 1 }
    ]
    queue_configs = [
      { queue_key = "technical-support", channel = "VOICE", priority = 1, delay_seconds = 0 },
      { queue_key = "customer-support", channel = "VOICE", priority = 2, delay_seconds = 120 },
      { queue_key = "general", channel = "VOICE", priority = 3, delay_seconds = 300 }
    ]
  }

  escalations-primary = {
    name                       = "Escalations-Primary"
    description                = "Restricted profile for Tier 2 escalation agents. No general overflow — escalations only."
    default_outbound_queue_key = "escalations"
    media_concurrencies = [
      { channel = "VOICE", concurrency = 1 }
    ]
    queue_configs = [
      { queue_key = "escalations", channel = "VOICE", priority = 1, delay_seconds = 0 }
    ]
  }

  general-primary = {
    name                       = "General-Primary"
    description                = "Primary profile for General Inbound agents."
    default_outbound_queue_key = "general"
    media_concurrencies = [
      { channel = "VOICE", concurrency = 1 }
    ]
    queue_configs = [
      { queue_key = "general", channel = "VOICE", priority = 1, delay_seconds = 0 }
    ]
  }

  omni = {
    name                       = "Omni-All-Queues"
    description                = "Omni profile for senior or overflow agents who can handle any queue. All queues at equal priority."
    default_outbound_queue_key = "general"
    media_concurrencies = [
      { channel = "VOICE", concurrency = 1 }
    ]
    queue_configs = [
      { queue_key = "general", channel = "VOICE", priority = 1, delay_seconds = 0 },
      { queue_key = "sales", channel = "VOICE", priority = 1, delay_seconds = 0 },
      { queue_key = "customer-support", channel = "VOICE", priority = 1, delay_seconds = 0 },
      { queue_key = "billing", channel = "VOICE", priority = 1, delay_seconds = 0 },
      { queue_key = "technical-support", channel = "VOICE", priority = 1, delay_seconds = 0 },
      { queue_key = "escalations", channel = "VOICE", priority = 1, delay_seconds = 0 }
    ]
  }

}
