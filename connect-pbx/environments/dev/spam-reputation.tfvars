# PRD-16 dev defaults. This keeps the module deployable without live
# third-party reputation providers while we validate the operator and
# state-management path end to end.

reputation_provider_mode = "mock"
reputation_providers     = ["hiya", "first_orion"]
reputation_api_secrets   = {}

attestation_provider_mode       = "mock"
attestation_provider_secret_arn = ""

enable_weekly_reputation_schedule  = false
enable_weekly_attestation_schedule = false

enable_high_spam_alarm   = true
enable_attestation_alarm = true
alarm_action_arns        = []
