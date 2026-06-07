# ---------------------------------------------------------------
# Phone Number Inventory - dev environment
# ---------------------------------------------------------------
# HOW TO ADD A NUMBER
#   1. Uncomment a stub below and fill in the fields, or copy a stub
#      and give it a new key.
#   2. Open a PR. CI will plan the change and show the new number
#      resource in the plan output.
#   3. Merge. The apply claims the number from the AWS telephony pool.
#   4. Check the phone_number_inventory output to see the actual E.164
#      digits that were assigned.
#
# HOW TO REMOVE A NUMBER (two-step process - prevent_destroy is active)
#   Step 1: Remove the lifecycle prevent_destroy block for that number
#           in main.tf, open a PR, merge, apply.
#   Step 2: Remove the entry from this file, open a PR, merge, apply.
#           The number is released back to the AWS pool permanently.
#           WARNING: Released numbers cannot be reclaimed.
#
# FIELD REFERENCE
#   type:         DID (local inbound) | TOLL_FREE (800/888/877 etc.)
#   country_code: ISO 3166-1 alpha-2 e.g. US, GB, CA, AU
#   prefix:       Optional area code hint e.g. "+1212" (NYC), "+1415" (SF).
#                 null = accept any available number in the country.
#                 AWS does not guarantee prefix availability. If unavailable,
#                 the apply fails with an error - try a different prefix.
#   purpose:      Human label for routing and reporting (main-inbound,
#                 sales, support, billing, etc.)
#   cost_center:  Business unit for cost allocation tagging.
#   cnam_name:    Optional per-number CNAM label for PRD-17 employee-name
#                 policy. Must be 15 characters or fewer when used.
#
# COST NOTE
#   Each US DID costs approximately $0.03/day (~$0.90/month).
#   Each US toll-free number costs approximately $0.06/day (~$1.80/month).
#   Numbers accrue charges immediately upon claim.
# ---------------------------------------------------------------

phone_numbers = {

  # --- ZERO-NUMBER DEV MODE ---
  # Leave this map empty while dev must deploy without claiming any
  # Amazon Connect phone numbers.
  #
  # HOW TO RESTORE TRUE PROVISIONED NUMBER MODE
  #   1. Uncomment the main-inbound block below, or add the exact number
  #      inventory you want dev to claim.
  #   2. Apply PRD-11 (modules/l1-phone-numbers).
  #   3. Restore number_flow_associations in
  #      environments/dev/contact-flows.tfvars.
  #   4. Apply PRD-14 (modules/l1-contact-flow-framework) so the
  #      claimed number is associated to the intended flow.

  # --- STUBS (uncomment and fill to provision) ---

  # main-inbound = {
  #   description  = "Main inbound DID - primary customer-facing number"
  #   type         = "DID"
  #   country_code = "US"
  #   prefix       = null
  #   purpose      = "main-inbound"
  #   cost_center  = "operations"
  #   cnam_name    = "MAIN LINE"
  # }

  # sales = {
  #   description  = "Sales team direct DID"
  #   type         = "DID"
  #   country_code = "US"
  #   prefix       = null   # e.g. "+1212" to request a NYC area code
  #   purpose      = "sales"
  #   cost_center  = "sales"
  #   cnam_name    = "SALES"
  # }

  # support = {
  #   description  = "Customer support DID"
  #   type         = "DID"
  #   country_code = "US"
  #   prefix       = null
  #   purpose      = "support"
  #   cost_center  = "support"
  #   cnam_name    = "SUPPORT"
  # }

  # billing = {
  #   description  = "Billing department direct DID"
  #   type         = "DID"
  #   country_code = "US"
  #   prefix       = null
  #   purpose      = "billing"
  #   cost_center  = "finance"
  #   cnam_name    = "BILLING"
  # }

  # tollfree-main = {
  #   description  = "National toll-free main number"
  #   type         = "TOLL_FREE"
  #   country_code = "US"
  #   prefix       = null   # e.g. "+1800" or "+1888" - not guaranteed
  #   purpose      = "main-inbound-tollfree"
  #   cost_center  = "operations"
  # }

}
