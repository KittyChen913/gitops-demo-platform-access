variable "openvpn_contact_email" {
  description = "Marketplace contact email supplied from the canonical SSM input at plan time."
  type        = string
  sensitive   = true
}

variable "ansible_ssh_public_key" {
  description = "Non-sensitive automation public key read from the credential-bootstrap SSM contract."
  type        = string
}

variable "openvpn_bootstrap_http_enabled" {
  description = "Temporarily allow TCP/80 for the Marketplace StackScript certbot bootstrap."
  type        = bool
  default     = false
}
