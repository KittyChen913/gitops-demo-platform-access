locals {
  deployment_config = jsondecode(file("${path.module}/../../../../config/shared.json"))
  automation_identity_contract = jsondecode(file(
    "${path.module}/../../../../${local.deployment_config.credential_bootstrap.automation_identity_contract_path}"
  ))
  material_version            = local.deployment_config.credential_bootstrap.material_version
  automation_password_version = local.deployment_config.credential_bootstrap.automation_password_version
  automation_identities = {
    for identity in local.automation_identity_contract.identities :
    identity.username => identity
  }
  automation_identity_cidr_range = {
    first = sum([
      for index, octet in split(".", cidrhost(local.deployment_config.network.automation_identity_cidr, 0)) :
      tonumber(octet) * pow(256, 3 - index)
    ])
    last = sum([
      for index, octet in split(".", cidrhost(local.deployment_config.network.automation_identity_cidr, -1)) :
      tonumber(octet) * pow(256, 3 - index)
    ])
  }
  automation_identity_ip_numbers = {
    for username, identity in local.automation_identities : username => sum([
      for index, octet in split(".", cidrhost("${identity.conn_ip}/32", 0)) :
      tonumber(octet) * pow(256, 3 - index)
    ])
  }
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

ephemeral "random_password" "automation_identity" {
  for_each = local.automation_identities

  length           = local.deployment_config.credential_bootstrap.automation_password_length
  special          = true
  min_lower        = 4
  min_upper        = 4
  min_numeric      = 4
  min_special      = 4
  override_special = "_%@-"
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

resource "aws_ssm_parameter" "automation_identity_password" {
  for_each = local.automation_identities

  name             = each.value.password_ssm_path
  type             = "SecureString"
  value_wo         = ephemeral.random_password.automation_identity[each.key].result
  value_wo_version = local.automation_password_version
}

check "credential_bootstrap_contract" {
  assert {
    condition = (
      local.material_version == 1 &&
      local.automation_password_version == 1 &&
      local.automation_identity_contract.schema_version == 2 &&
      local.automation_identity_contract.group == "ci-automation" &&
      length(local.automation_identities) == 3 &&
      alltrue([
        for username, identity in local.automation_identities :
        startswith(identity.profile_ssm_path, "/gitops/openvpn-dns/automation/${username}/") &&
        startswith(identity.password_ssm_path, "/gitops/openvpn-dns/automation/${username}/") &&
        endswith(identity.profile_ssm_path, "/PROFILE") &&
        endswith(identity.password_ssm_path, "/PASSWORD") &&
        identity.public_egress == contains(["ci-cluster", "ci-argocd"], username) &&
        local.automation_identity_ip_numbers[username] > local.automation_identity_cidr_range.first + 1 &&
        local.automation_identity_ip_numbers[username] < local.automation_identity_cidr_range.last - 1
      ]) &&
      length(distinct([
        for identity in values(local.automation_identities) : identity.conn_ip
      ])) == length(local.automation_identities) &&
      startswith(local.deployment_config.aws.ssm_parameter_paths.openvpn_admin_password, "/gitops/openvpn-dns/") &&
      startswith(local.deployment_config.aws.ssm_parameter_paths.openvpn_ssh_private_key_b64, "/gitops/openvpn-dns/") &&
      startswith(local.deployment_config.aws.ssm_parameter_paths.openvpn_ssh_public_key, "/gitops/openvpn-dns/")
    )
    error_message = "Credential bootstrap must use the approved OpenVPN/DNS SSM contract."
  }
}
