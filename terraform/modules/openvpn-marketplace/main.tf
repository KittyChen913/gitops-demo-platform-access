locals {
  stackscript_data = {
    user_name         = var.automation_username
    disable_root      = "Yes"
    soa_email_address = var.contact_email
    add_ons           = "none"
  }
}

resource "linode_networking_ip" "openvpn" {
  type     = "ipv4"
  public   = true
  reserved = true
  region   = var.region
}

resource "linode_firewall" "openvpn" {
  label           = "${var.label}-firewall"
  inbound_policy  = "DROP"
  outbound_policy = "ACCEPT"
  tags            = var.tags

  inbound {
    label    = "allow-openvpn-clients"
    action   = "ACCEPT"
    protocol = upper(var.openvpn_protocol)
    ports    = tostring(var.openvpn_port)
    ipv4     = ["0.0.0.0/0"]
  }
}

resource "linode_instance" "openvpn" {
  label            = var.label
  region           = var.region
  type             = var.instance_type
  image            = var.image
  ipv4             = [linode_networking_ip.openvpn.address]
  stackscript_id   = var.stackscript_id
  stackscript_data = local.stackscript_data
  authorized_keys  = [trimspace(var.ssh_public_key)]
  firewall_id      = linode_firewall.openvpn.id
  tags             = var.tags

  lifecycle {
    precondition {
      condition = (
        var.stackscript_id == 401719 &&
        var.image == "linode/ubuntu24.04" &&
        can(regex("^[a-z_][a-z0-9_-]{0,31}$", var.automation_username)) &&
        can(regex("^ssh-ed25519 [A-Za-z0-9+/]+={0,3}( .*)?$", trimspace(var.ssh_public_key)))
      )
      error_message = "The approved Marketplace ID/image and credential-bootstrap public-key contract are required."
    }

    postcondition {
      condition     = contains(self.ipv4, linode_networking_ip.openvpn.address)
      error_message = "The Shared OpenVPN Instance is not using the Terraform-owned Reserved IPv4."
    }
  }
}
