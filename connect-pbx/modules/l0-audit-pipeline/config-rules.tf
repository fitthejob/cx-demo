resource "aws_config_config_rule" "required_tags" {
  name        = "${var.org_name}-required-tags"
  description = "FR-011: Checks that all resources carry the mandatory tag set"

  source {
    owner             = "AWS"
    source_identifier = "REQUIRED_TAGS"
  }

  input_parameters = jsonencode({
    tag1Key = "Project"
    tag2Key = "Layer"
    tag3Key = "PRD"
    tag4Key = "Environment"
    tag5Key = "ManagedBy"
  })

  depends_on = [aws_config_configuration_recorder_status.main]
}
