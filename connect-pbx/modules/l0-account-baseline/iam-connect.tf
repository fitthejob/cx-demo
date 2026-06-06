locals {
  account_baseline_module_bash_path = replace(path.module, "\\", "/")
}

data "external" "connect_service_linked_role_existing" {
  program = [
    "bash",
    "${local.account_baseline_module_bash_path}/scripts/connect-service-linked-role.sh",
    "lookup",
  ]

  query = {
    role_name = "AWSServiceRoleForAmazonConnect"
  }
}

resource "terraform_data" "ensure_connect_service_linked_role" {
  input = {
    role_name = "AWSServiceRoleForAmazonConnect"
  }

  provisioner "local-exec" {
    interpreter = ["bash", "-lc"]
    command     = "'${local.account_baseline_module_bash_path}/scripts/connect-service-linked-role.sh' ensure"
  }
}

data "external" "connect_service_linked_role_resolved" {
  depends_on = [terraform_data.ensure_connect_service_linked_role]

  program = [
    "bash",
    "${local.account_baseline_module_bash_path}/scripts/connect-service-linked-role.sh",
    "lookup",
  ]

  query = {
    role_name = "AWSServiceRoleForAmazonConnect"
  }
}

locals {
  connect_service_linked_role_arn = (
    data.external.connect_service_linked_role_existing.result.exists == "true"
    ? data.external.connect_service_linked_role_existing.result.arn
    : data.external.connect_service_linked_role_resolved.result.arn
  )
}
