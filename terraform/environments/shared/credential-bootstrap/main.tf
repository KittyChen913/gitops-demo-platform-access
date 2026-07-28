locals {
  deployment_config = jsondecode(file("${path.module}/../../../../config/shared.json"))
  material_version  = local.deployment_config.credential_bootstrap.material_version
}

ephemeral "random_password" "openvpn_admin" {
  length           = local.deployment_config.credential_bootstrap.admin_password_length
  special          = true
  min_lower        = 4
  min_upper        = 4
  min_numeric      = 4
  min_special      = 4
  override_special = "_%@-"
}

ephemeral "tls_private_key" "ansible" {
  algorithm = "ED25519"
}

resource "aws_ssm_parameter" "openvpn_admin_password" {
  name             = local.deployment_config.aws.ssm_parameter_paths.openvpn_admin_password
  type             = "SecureString"
  value_wo         = ephemeral.random_password.openvpn_admin.result
  value_wo_version = local.material_version
}

resource "aws_ssm_parameter" "openvpn_ssh_private_key_b64" {
  name             = local.deployment_config.aws.ssm_parameter_paths.openvpn_ssh_private_key_b64
  type             = "SecureString"
  value_wo         = base64encode(ephemeral.tls_private_key.ansible.private_key_openssh)
  value_wo_version = local.material_version
}

resource "aws_ssm_parameter" "openvpn_ssh_public_key" {
  name             = local.deployment_config.aws.ssm_parameter_paths.openvpn_ssh_public_key
  type             = "String"
  value_wo         = trimspace(ephemeral.tls_private_key.ansible.public_key_openssh)
  value_wo_version = local.material_version
}

check "credential_bootstrap_contract" {
  assert {
    condition = (
      local.material_version == 1 &&
      startswith(local.deployment_config.aws.ssm_parameter_paths.openvpn_admin_password, "/gitops/platform-access/") &&
      startswith(local.deployment_config.aws.ssm_parameter_paths.openvpn_ssh_private_key_b64, "/gitops/platform-access/") &&
      startswith(local.deployment_config.aws.ssm_parameter_paths.openvpn_ssh_public_key, "/gitops/platform-access/")
    )
    error_message = "Credential bootstrap must use the approved Platform Access SSM contract."
  }
}
