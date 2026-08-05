locals {
  deployment_config = jsondecode(file("${path.module}/../../../../config/shared.json"))
  vpn_address_cidrs = [
    local.deployment_config.network.vpn_client_cidr,
    local.deployment_config.network.vpn_group_default_cidr,
    local.deployment_config.network.automation_identity_cidr,
  ]
  vpn_address_ranges = [
    for cidr in local.vpn_address_cidrs : {
      first = sum([
        for index, octet in split(".", cidrhost(cidr, 0)) :
        tonumber(octet) * pow(256, 3 - index)
      ])
      last = sum([
        for index, octet in split(".", cidrhost(cidr, -1)) :
        tonumber(octet) * pow(256, 3 - index)
      ])
    }
  ]
}

check "network_contract" {
  assert {
    condition     = local.deployment_config.network.internal_dns_ip == cidrhost(local.deployment_config.network.vpn_client_cidr, 1)
    error_message = "The internal DNS address must be the first host in the VPN client CIDR."
  }

  assert {
    condition = alltrue(flatten([
      for left_index, left_range in local.vpn_address_ranges : [
        for right_index, right_range in local.vpn_address_ranges :
        left_index == right_index ||
        left_range.last < right_range.first ||
        right_range.last < left_range.first
      ]
    ]))
    error_message = "The dynamic, group-default, and automation VPN CIDRs must not overlap."
  }
}

check "credential_inputs" {
  assert {
    condition = (
      can(regex("^[^@[:space:]]+@[^@[:space:]]+\\.[^@[:space:]]+$", var.openvpn_contact_email)) &&
      can(regex("^ssh-ed25519 [A-Za-z0-9+/]+={0,3}( .*)?$", trimspace(var.ansible_ssh_public_key))) &&
      local.deployment_config.linode.automation_username == "vpnadmin" &&
      local.deployment_config.linode.openvpn_admin_username == "openvpn"
    )
    error_message = "BASE requires the approved contact-email, SSH public-key, sudo-user, and OpenVPN administrator contracts."
  }
}

module "openvpn" {
  source = "../../../modules/openvpn-marketplace"

  label               = local.deployment_config.linode.instance_label
  region              = local.deployment_config.linode.region
  instance_type       = local.deployment_config.linode.instance_type
  image               = local.deployment_config.linode.image
  stackscript_id      = local.deployment_config.linode.marketplace_stackscript_id
  automation_username = local.deployment_config.linode.automation_username
  contact_email       = var.openvpn_contact_email
  ssh_public_key      = var.ansible_ssh_public_key
  openvpn_port        = local.deployment_config.linode.openvpn_port
  openvpn_protocol    = local.deployment_config.linode.openvpn_protocol
  tags                = ["gitops-demo", "platform-access", "openvpn", "shared"]

  bootstrap_http_enabled = var.openvpn_bootstrap_http_enabled
}

resource "aws_ssm_parameter" "vpn_public_egress_ip" {
  name  = local.deployment_config.aws.ssm_parameter_paths.vpn_public_egress_ip
  type  = "String"
  value = module.openvpn.reserved_ipv4
}

resource "aws_ssm_parameter" "vpn_client_cidr" {
  name  = local.deployment_config.aws.ssm_parameter_paths.vpn_client_cidr
  type  = "String"
  value = local.deployment_config.network.vpn_client_cidr
}

resource "aws_ssm_parameter" "internal_dns_ip" {
  name  = local.deployment_config.aws.ssm_parameter_paths.internal_dns_ip
  type  = "String"
  value = local.deployment_config.network.internal_dns_ip
}

resource "aws_ssm_parameter" "internal_domain" {
  name  = local.deployment_config.aws.ssm_parameter_paths.internal_domain
  type  = "String"
  value = local.deployment_config.network.internal_domain

  lifecycle {
    prevent_destroy = true
  }
}
