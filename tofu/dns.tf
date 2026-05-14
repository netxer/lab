provider "unifi" {
  api_key = var.unifi_api_key  # optionally use UNIFI_API_KEY env var
  api_url = var.unifi_api_url  # optionally use UNIFI_API env var
}

# DNS record for Ansible controller
resource "unifi_dns_record" "ansible_controller" {
  count  = length(proxmox_virtual_environment_vm.ansible_controller)
  name   = "${proxmox_virtual_environment_vm.ansible_controller[count.index].name}.lab.sinofage.com"
  type   = "A"
  record = proxmox_virtual_environment_vm.ansible_controller[count.index].ipv4_addresses[1][0]
  ttl    = 0
}

# DNS records for control VMs
resource "unifi_dns_record" "control" {
  count  = var.control_count
  name   = "${proxmox_virtual_environment_vm.control_vm[count.index].name}.lab.sinofage.com"
  type   = "A"
  record = proxmox_virtual_environment_vm.control_vm[count.index].ipv4_addresses[1][0]
  ttl    = 0
}

# DNS records for node VMs
resource "unifi_dns_record" "node" {
  count  = var.node_count
  name   = "${proxmox_virtual_environment_vm.node[count.index].name}.lab.sinofage.com"
  type   = "A"
  record = proxmox_virtual_environment_vm.node[count.index].ipv4_addresses[1][0]
  ttl    = 0
}

