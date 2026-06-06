resource "aws_cloudwatch_metric_alarm" "queue_depth" {
  for_each = local.enabled_queues

  alarm_name          = "${var.org_name}-queue-depth-${each.key}-${terraform.workspace}"
  alarm_description   = "ALARM-13-01: Queue ${each.key} depth exceeds threshold — callers accumulating"
  namespace           = "AWS/Connect"
  metric_name         = "QueueSize"
  statistic           = "Maximum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 20
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.alarm_action_arns

  dimensions = {
    InstanceId  = local.connect_instance_id
    MetricGroup = "Queue"
    QueueName   = aws_connect_queue.queues[each.key].name
  }

  tags = merge(local.common_tags, {
    QueueKey = each.key
  })
}

resource "aws_cloudwatch_metric_alarm" "oldest_contact" {
  for_each = {
    for k, v in local.enabled_queues : k => v if v.max_wait_minutes > 0
  }

  alarm_name          = "${var.org_name}-oldest-contact-${each.key}-${terraform.workspace}"
  alarm_description   = "ALARM-13-02: Queue ${each.key} oldest contact approaching overflow timeout (80% of max_wait_minutes)"
  namespace           = "AWS/Connect"
  metric_name         = "OldestContactAge"
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 1
  threshold           = each.value.max_wait_minutes * 60 * 0.8
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.alarm_action_arns

  dimensions = {
    InstanceId  = local.connect_instance_id
    MetricGroup = "Queue"
    QueueName   = aws_connect_queue.queues[each.key].name
  }

  tags = merge(local.common_tags, {
    QueueKey = each.key
  })
}
