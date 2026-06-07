# ---------------------------------------------------------------
# Contact Flow Configuration - dev environment
# ---------------------------------------------------------------
# This file controls customer-facing prompt text and the mapping from
# claimed phone numbers to PRD-14 contact flows.
# ---------------------------------------------------------------

enable_audit_integration = false

tts_voice_id      = "Joanna"
tts_language_code = "en-US"

flow_prompts = {
  greeting              = "Thank you for calling our company."
  main_menu             = "For sales, press 1. For customer support, press 2. For billing, press 3. For technical support, press 4. To repeat this menu, press 0."
  after_hours           = "Our office is currently closed."
  callback_offer        = "To request a callback when we reopen, press 1. To leave a voicemail message, press 2."
  queue_wait            = "Please hold while we connect you to the next available agent."
  overflow              = "We are unable to connect you right now."
  error                 = "We are having trouble processing your call."
  goodbye               = "Goodbye."
  voicemail_unavailable = "Voicemail is not available right now."
}

number_flow_associations = {
  # ZERO-NUMBER DEV MODE:
  # Leave this map empty while PRD-11 is intentionally managing zero
  # claimed numbers in dev.
  #
  # HOW TO RESTORE TRUE PROVISIONED NUMBER MODE
  #   1. Restore the desired number entries in
  #      environments/dev/phone-numbers.tfvars.
  #   2. Apply PRD-11 first so phone_number_ids and
  #      phone_number_inventory are populated.
  #   3. Uncomment the association(s) below.
  #   4. Apply PRD-14 to bind the claimed number(s) to the target
  #      flow(s).

  # main-inbound = "main-inbound"
}
