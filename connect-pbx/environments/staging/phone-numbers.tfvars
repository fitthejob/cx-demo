# Staging baseline mirrors dev until staging-specific number inventory is finalized.

phone_numbers = {
  main-inbound = {
    description  = "Main inbound DID — staging"
    type         = "DID"
    country_code = "US"
    prefix       = null
    purpose      = "main-inbound"
    cost_center  = "operations"
  }
}
