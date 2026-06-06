locals {
  # Filter to only enabled queues
  enabled_queues = {
    for k, v in var.queues : k => v if v.enabled
  }

  # Validate that every queue_key referenced in routing_profiles exists in var.queues and is enabled.
  # This produces a clear error at plan time rather than a confusing for_each key lookup failure.
  _routing_profile_queue_key_validation = [
    for profile_key, profile in var.routing_profiles : [
      for qc in profile.queue_configs :
      lookup(local.enabled_queues, qc.queue_key, null) != null
      ? true
      : tobool("ERROR: routing profile '${profile_key}' references queue key '${qc.queue_key}' which is not in var.queues or is disabled")
    ]
  ]
}
