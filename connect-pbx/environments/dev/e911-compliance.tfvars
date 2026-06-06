# PRD-18 dev defaults. These values keep the module deployable and testable
# without sending real security notifications, real registration emails, or
# real E911 provider updates.

e911_provider            = "bandwidth"
e911_provider_mode       = "mock"
e911_provider_secret_arn = ""
allow_live_provider_sync = false

notification_delivery_mode        = "mock"
registration_email_delivery_mode  = "mock"
allow_live_external_notifications = false
remote_registration_sender_email  = ""

security_alert_endpoints                     = []
enable_security_alert_endpoint_subscriptions = false

elin_assignment_mode = "mock"

enable_daily_provider_sync_schedule    = false
enable_daily_compliance_audit_schedule = false

alarm_action_arns = []
