locals {
  deployment_config = jsondecode(file("${path.module}/../../../../config/shared.json"))
}

check "network_contract" {
  assert {
    condition     = local.deployment_config.network.internal_dns_ip == cidrhost(local.deployment_config.network.vpn_client_cidr, 1)
    error_message = "The internal DNS address must be the first host in the VPN client CIDR."
  }
}

check "credential_inputs" {
  assert {
    condition = (
      can(regex("^[^@[:space:]]+@[^@[:space:]]+\\.[^@[:space:]]+$", var.openvpn_contact_email)) &&
      can(regex("^ssh-ed25519 [A-Za-z0-9+/]+={0,3}( .*)?$", trimspace(var.ansible_ssh_public_key)))
    )
    error_message = "BASE requires the approved contact-email and credential-bootstrap SSH public-key contracts."
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
