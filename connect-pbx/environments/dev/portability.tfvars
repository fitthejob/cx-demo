# PRD-15 is migration-only and is not enabled in the default bare-bones
# deployment manifest. These values are ready when the migration pack is
# intentionally enabled in dev.

lookup_provider            = "mock"
lookup_provider_secret_arn = ""
check_expiry_days          = 30
history_ttl_days           = 365
