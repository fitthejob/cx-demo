# PRD-17 dev defaults. This keeps CNAM registration deployable and testable
# in dev without live carrier-side CNAM provider APIs.

cnam_policy       = "company"
cnam_company_name = "YOUR COMPANY"

cnam_provider            = "bandwidth"
cnam_provider_mode       = "mock"
cnam_provider_secret_arn = ""

enable_weekly_verification_schedule = false
enable_submission_failure_alarm     = true
enable_drift_alarm                  = true
alarm_action_arns                   = []
