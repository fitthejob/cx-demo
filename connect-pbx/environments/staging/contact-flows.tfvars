# Staging baseline mirrors dev until staging-specific call flow wording is finalized.

enable_audit_integration = true

tts_voice_id      = "Joanna"
tts_language_code = "en-US"

flow_prompts = {
  greeting              = "Thank you for calling our company staging."
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
  main-inbound = "main-inbound"
}
