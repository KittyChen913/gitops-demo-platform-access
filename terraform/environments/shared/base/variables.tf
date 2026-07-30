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
  description = "是否暫時開放 TCP/80 供 Marketplace StackScript 內建的 Let's Encrypt certbot 驗證使用；CI 只在偵測到需要 bootstrap 時才會帶 true。"
  type        = bool
  default     = false
}
