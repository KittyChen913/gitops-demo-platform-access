variable "label" { type = string }
variable "region" { type = string }
variable "instance_type" { type = string }
variable "image" { type = string }
variable "stackscript_id" { type = number }
variable "automation_username" { type = string }

variable "contact_email" {
  type      = string
  sensitive = true
}

variable "ssh_public_key" { type = string }
variable "openvpn_port" { type = number }
variable "openvpn_protocol" { type = string }
variable "tags" { type = list(string) }
