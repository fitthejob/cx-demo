output "queue_ids" {
  description = "Map of queue key to Connect queue ID. Consumed by PRD-14 and PRD-53."
  value = {
    for k, v in aws_connect_queue.queues : k => v.queue_id
  }
}

output "queue_arns" {
  description = "Map of queue key to queue ARN. Consumed by PRD-14 and PRD-91."
  value = {
    for k, v in aws_connect_queue.queues : k => v.arn
  }
}

output "routing_profile_ids" {
  description = "Map of routing profile key to routing profile ID. Consumed by PRD-50."
  value = {
    for k, v in aws_connect_routing_profile.profiles : k => v.routing_profile_id
  }
}

output "routing_profile_arns" {
  description = "Map of routing profile key to ARN."
  value = {
    for k, v in aws_connect_routing_profile.profiles : k => v.arn
  }
}

output "queue_config" {
  description = "Full resolved queue config including IDs, strategy, overflow action, and max wait. Consumed by PRD-14 to build contact flow logic."
  value = {
    for k, v in aws_connect_queue.queues : k => {
      queue_id         = v.queue_id
      queue_arn        = v.arn
      name             = v.name
      routing_strategy = var.queues[k].routing_strategy
      overflow_action  = var.queues[k].overflow_action
      max_wait_minutes = var.queues[k].max_wait_minutes
      priority         = var.queues[k].priority
      cost_center      = var.queues[k].cost_center
    }
  }
}

output "system_queue_id" {
  description = "System internal queue ID. Convenience output for PRD-53, PRD-60. Returns null if no 'system' queue is defined."
  value       = try(aws_connect_queue.queues["system"].queue_id, null)
}

output "system_queue_arn" {
  description = "System internal queue ARN. Returns null if no 'system' queue is defined."
  value       = try(aws_connect_queue.queues["system"].arn, null)
}
