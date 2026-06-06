# PRD-19 dev defaults. This keeps routing drift detection deployable and
# manually testable in dev before we enable the 15-minute schedule.

module_state_resolution = {
  state_bucket            = "<state_bucket_name>"
  phone_numbers_state_key = "l1-phone-numbers/terraform.tfstate"
  contact_flow_state_key  = "l1-contact-flow-framework/terraform.tfstate"

  # Connect instance ID — sourced from l1-connect-instance module output.
  # Update this value after initial Connect instance deployment.
  connect_instance_ids    = ["<connect_instance_id>"]
}

enable_schedule               = false
enable_drift_detected_alarm   = true
enable_persistent_drift_alarm = true
alarm_action_arns             = []
