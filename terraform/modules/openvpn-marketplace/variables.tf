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

variable "bootstrap_http_enabled" {
  description = "是否暫時開放 TCP/80 供 Marketplace StackScript 內建的 Let's Encrypt certbot 驗證使用；只能在偵測到需要 bootstrap 時暫開，Access Server ready 後必須改回 false 並重新 apply。"
  type        = bool
  default     = false
}
