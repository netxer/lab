terraform {
  required_providers {
    proxmox = {
      source = "bpg/proxmox"
      version = "0.106.0"
    }
    unifi = {
      source = "filipowm/unifi"
      version = "1.0.0"
    }
  }
}

provider "proxmox" {
  endpoint = var.proxmox_nuc_endpoint
  username = var.proxmox_user
  password = var.proxmox_password
  insecure = var.proxmox_tls_insecure
  random_vm_ids = true

  ssh {
    #TODO: figure out how to fix the ssh agent issue / Works on windows need to check why on macos it has issues with 1pass agent
    agent = false
    username = "root"
    private_key = file("~/.ssh/Michelle SSH Key")
  }
}

###############
# Local image #
###############
data "proxmox_virtual_environment_file" "imported_file" {
  node_name    = "nucpve"
  datastore_id = "local"
  content_type = "import"
  file_name    = "temp.qcow2"
}

######################
# SSH key generation #
######################
resource "tls_private_key" "vm_key" {
  algorithm = "RSA"
  rsa_bits  = 2048
}
#######################
# Output IP addresses #
#######################

output "ansible_controller_vm_ips" {
  description = "IP addresses of ansible controller VMs"
  value = {
    for idx, vm in proxmox_virtual_environment_vm.ansible_controller :
    vm.name => vm.ipv4_addresses[1][0]
  }
}

output "control_vm_ips" {
  description = "IP addresses of control VMs"
  value = {
    for idx, vm in proxmox_virtual_environment_vm.control_vm :
    vm.name => vm.ipv4_addresses[1][0]
  }
}

output "worker_vm_ips" {
  description = "IP addresses of worker VMs (DHCP)"
  value = {
    for idx, vm in proxmox_virtual_environment_vm.node :
    vm.name => vm.ipv4_addresses[1][0]
  }
}

######################
# Output private key #
######################

output "vm_private_key" {
  value     = tls_private_key.vm_key.private_key_pem
  sensitive = true
}

#####################
# Output public key #
#####################

output "vm_public_key" {
  value = tls_private_key.vm_key.public_key_openssh
}

######################
# Output private key #
######################

resource "local_file" "vm_private_key" {
  filename        = "${path.module}/../ansible/ansible_key.pem"
  content         = tls_private_key.vm_key.private_key_pem
  file_permission = "0600"
}

#####################
# Ansible inventory #
#####################

resource "local_file" "ansible_inventory" {
  filename = "${path.module}/../ansible/inv/ansible_inventory.ini"
  content  = <<-EOT
[control]
%{for vm in proxmox_virtual_environment_vm.control_vm~}
${vm.name} ansible_host=${vm.name}.lab.sinofage.com ansible_user=ubuntu
%{endfor~}

[workers]
%{for vm in proxmox_virtual_environment_vm.node~}
${vm.name} ansible_host=${vm.name}.lab.sinofage.com ansible_user=ubuntu
%{endfor~}

[all:vars]
ansible_ssh_common_args='-o StrictHostKeyChecking=no'
  EOT
}

####################
# Ansible playbook #
####################

resource "local_file" "ansible_playbook" {
  filename = "${path.module}/../ansible/test-connectivity.yml"
  content  = <<-EOT
---
- name: Test connectivity to all hosts
  hosts: all
  gather_facts: no
  tasks:
    - name: Ping all hosts
      ansible.builtin.ping:
      register: ping_result

    - name: Display ping result
      ansible.builtin.debug:
        msg: "Host {{ inventory_hostname }} is reachable"
      when: ping_result is succeeded

- name: Test SSH login and gather facts
  hosts: all
  gather_facts: yes
  tasks:
    - name: Display hostname
      ansible.builtin.debug:
        msg: "Successfully logged into {{ ansible_hostname }} ({{ ansible_distribution }} {{ ansible_distribution_version }})"

    - name: Check uptime
      ansible.builtin.command: uptime
      register: uptime_result
      changed_when: false

    - name: Display uptime
      ansible.builtin.debug:
        msg: "{{ uptime_result.stdout }}"
  EOT
}

########################################
# Transfer files to ansible controller #
########################################

resource "null_resource" "transfer_ansible_files" {
  depends_on = [
    proxmox_virtual_environment_vm.ansible_controller,
    local_file.ansible_inventory,
    local_file.ansible_playbook,
    local_file.vm_private_key
  ]

  # Wait for cloud-init to finish first
  provisioner "remote-exec" {
    inline = ["cloud-init status --wait"]
    connection {
      host        = proxmox_virtual_environment_vm.ansible_controller[0].ipv4_addresses[1][0]
      user        = "ubuntu"
      private_key = tls_private_key.vm_key.private_key_pem
    }
  }
  
  provisioner "local-exec" {
    command = <<-EOT
      scp -i ${local_file.vm_private_key.filename} -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null ${local_file.ansible_inventory.filename} ubuntu@${proxmox_virtual_environment_vm.ansible_controller[0].ipv4_addresses[1][0]}:/home/ubuntu/ansible_inventory.ini
      scp -i ${local_file.vm_private_key.filename} -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null ${local_file.ansible_playbook.filename} ubuntu@${proxmox_virtual_environment_vm.ansible_controller[0].ipv4_addresses[1][0]}:/home/ubuntu/test-connectivity.yml
    EOT
  }

  triggers = {
    inventory_content = local_file.ansible_inventory.content
    playbook_content  = local_file.ansible_playbook.content
    vm_id             = proxmox_virtual_environment_vm.ansible_controller[0].id
  }
}