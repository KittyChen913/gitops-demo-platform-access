output "openvpn_instance_id" {
  description = "Shared OpenVPN Linode identity used by deployment host attestation."
  value       = module.openvpn.instance_id
}

output "openvpn_firewall_id" {
  description = "Shared OpenVPN Firewall identity used by the temporary runner /32 lease adapter."
  value       = module.openvpn.firewall_id
}

output "openvpn_reserved_ipv4" {
  description = "Reserved public IPv4 and canonical VPN egress contract."
  value       = module.openvpn.reserved_ipv4
}
