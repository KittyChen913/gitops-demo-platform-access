output "instance_id" {
  value = linode_instance.openvpn.id
}

output "firewall_id" {
  value = linode_firewall.openvpn.id
}

output "reserved_ipv4" {
  value = linode_networking_ip.openvpn.address
}
