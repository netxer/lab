variable "proxmox_endpoint" {
  description = "Proxmox API URL (e.g., https://192.168.4.100:8006)"
  type        = string
}

variable "proxmox_user" {
  description = "Proxmox user (e.g., root@pam)"
  type        = string
}

variable "proxmox_password" {
  description = "Proxmox password"
  type        = string
  sensitive   = true
}

variable "proxmox_tls_insecure" {
  description = "Skip TLS verification"
  type        = bool
}

variable "proxmox_node" {
  description = "Proxmox node name"
  type        = string
}

variable "control_count" {
  description = "Number of control VMs to create"
  type        = number
  default     = 3
}

variable "node_count" {
  description = "Number of node VMs to create"
  type        = number
  default     = 3
}

variable "unifi_username" {
  description = "Unifi controller username"
  type        = string
}

variable "unifi_password" {
  description = "Unifi controller password"
  type        = string
  sensitive   = true
}

variable "unifi_api_url" {
  description = "Unifi controller API URL"
  type        = string
}

# variable "unifi_insecure" {
#   description = "Skip TLS verification"
#   type        = bool
# }

variable "unifi_api_key" {
  description = "Unifi API key"
  type        = string
  sensitive   = true
}
