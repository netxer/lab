######################
# Ansible controller #
######################

resource "proxmox_virtual_environment_vm" "ansible_controller" {
  count     = 1
  name      = "ansible-${count.index + 1}"
  node_name = "nucpve"

  # should be true if qemu agent is not installed / enabled on the VM
  stop_on_destroy = true

  network_device {
    bridge = "vmbr0"
  }
  
  agent {
    # read 'Qemu guest agent' section, change to true only when ready
    enabled = true
  }
  
  initialization {
    ip_config {
      ipv4 {
        address = "192.168.4.${5 + count.index}/24"
        gateway = "192.168.4.1"
      }
    }
    user_data_file_id = proxmox_virtual_environment_file.ansible_controller_cloud_config[count.index].id
  }

  cpu {
    cores        = 4
    type         = "host"  # recommended for modern CPUs
  }

  memory {
    dedicated = 2048
    floating  = 2048 # set equal to dedicated to enable ballooning
  }

  disk {
    datastore_id = "ssd"
    import_from  = data.proxmox_virtual_environment_file.imported_file.id
    interface    = "virtio0"
    iothread     = true
    discard      = "on"
    size         = 20
  }
}

######################
# Control VMs #
######################

resource "proxmox_virtual_environment_vm" "control_vm" {
  count     = var.control_count
  name      = "control-${count.index + 1}"
  node_name = "nucpve"

  # should be true if qemu agent is not installed / enabled on the VM
  stop_on_destroy = true

  network_device {
    bridge = "vmbr0"
  }
  
  agent {
    # read 'Qemu guest agent' section, change to true only when ready
    enabled = true
  }
  

  initialization {
    ip_config {
      ipv4 {
        address = "dhcp"
      }
    }

    user_data_file_id = proxmox_virtual_environment_file.control_vm_cloud_config[count.index].id
  }

  cpu {
    cores        = 4
    type         = "host"  # recommended for modern CPUs
  }

  memory {
    dedicated = 2048
    floating  = 2048 # set equal to dedicated to enable ballooning
  }

  disk {
    datastore_id = "ssd"
    import_from  = data.proxmox_virtual_environment_file.imported_file.id
    interface    = "virtio0"
    iothread     = true
    discard      = "on"
    size         = 20
  }

  lifecycle {
    create_before_destroy = true
  }
}

######################
# Node VMs #
######################
resource "proxmox_virtual_environment_vm" "node" {
  count     = var.node_count
  name      = "node-${count.index + 1}"
  node_name = "nucpve"

  # should be true if qemu agent is not installed / enabled on the VM
  stop_on_destroy = true

  network_device {
    bridge = "vmbr0"
  }
  
  agent {
    # read 'Qemu guest agent' section, change to true only when ready
    enabled = true
  }
  

  initialization {
    ip_config {
      ipv4 {
        address = "dhcp" 
      }
    }
    user_data_file_id = proxmox_virtual_environment_file.node_vm_cloud_config[count.index].id
  }

  cpu {
    cores        = 4
    type         = "host"  # recommended for modern CPUs
  }

  memory {
    dedicated = 2048
    floating  = 2048 # set equal to dedicated to enable ballooning
  }

  disk {
    datastore_id = "ssd"
    import_from  = data.proxmox_virtual_environment_file.imported_file.id
    interface    = "virtio0"
    iothread     = true
    discard      = "on"
    size         = 20
  }

  lifecycle {
    create_before_destroy = true
  }
}