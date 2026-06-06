# ---------------------------------------------------------------
# Phone Number Inventory — prod environment
# ---------------------------------------------------------------
# See OQ-11-01: The complete production number inventory is a business
# decision. Replace the placeholder entries below with actual numbers
# required before prod apply.
#
# For ported numbers (existing client numbers from RingCentral, 8x8,
# Cisco, Avaya): do NOT add them here before porting is complete.
# After porting, import them into state using the procedure in
# connect-pbx/docs/runbooks/RB-11-02-porting-and-cutover.md,
# then add the entry to this file.
# ---------------------------------------------------------------

phone_numbers = {

  main-inbound = {
    description  = "Main inbound DID — primary customer number"
    type         = "DID"
    country_code = "US"
    prefix       = null
    purpose      = "main-inbound"
    cost_center  = "operations"
  }

  # sales = {
  #   description  = "Sales team direct DID"
  #   type         = "DID"
  #   country_code = "US"
  #   prefix       = null
  #   purpose      = "sales"
  #   cost_center  = "sales"
  # }

  # support = {
  #   description  = "Customer support DID"
  #   type         = "DID"
  #   country_code = "US"
  #   prefix       = null
  #   purpose      = "support"
  #   cost_center  = "support"
  # }

  # tollfree-main = {
  #   description  = "National toll-free main number"
  #   type         = "TOLL_FREE"
  #   country_code = "US"
  #   prefix       = null
  #   purpose      = "main-inbound-tollfree"
  #   cost_center  = "operations"
  # }

}
