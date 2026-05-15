packer {
  required_plugins {
    proxmox = {
      version = ">= 1.2.3"
      source  = "github.com/hashicorp/proxmox"
    }
  }
}

variable "proxmox_url" {
  type    = string
  default = "https://192.168.4.100:8006/api2/json"
}

variable "proxmox_token_id" {
  type = string
}

variable "proxmox_token_secret" {
  type      = string
  sensitive = true
}

source "proxmox-iso" "ubuntu" {
  proxmox_url              = var.proxmox_url
  username                 = var.proxmox_token_id
  token                    = var.proxmox_token_secret
  insecure_skip_tls_verify = true
  node                     = "nucpve"

  # VM settings
  vm_name              = "ubuntu-template"
  template_description = "Ubuntu 26.04 base template built by Packer"
  qemu_agent           = true
  cores                = 4
  memory               = 16384
  scsi_controller      = "virtio-scsi-pci"

  disks {
    type         = "scsi"
    disk_size    = "20G"
    storage_pool = "local-lvm"
    ssd          = true
  }

  network_adapters {
    model  = "virtio"
    bridge = "vmbr0"
  }

  # ISO - download Ubuntu server ISO to Proxmox first
  boot_iso {
  iso_file = "local:iso/ubuntu-26.04-live-server-amd64.iso"
  unmount = true
}
  # Cloud-init support
  cloud_init              = true
  cloud_init_storage_pool = "local-lvm"

  # Boot command for autoinstall (Ubuntu 26.04)
  boot_wait = "5s"
  boot_command = [
    "c<wait>",
    "linux /casper/vmlinuz --- autoinstall ds='nocloud-net;s=http://{{ .HTTPIP }}:{{ .HTTPPort }}/'",
    "<enter><wait5>",
    "initrd /casper/initrd",
    "<enter><wait2>",
    "boot",
    "<enter>"
  ]
  
  # Packer serves this directory over HTTP for autoinstall
  http_directory = "http"

  # SSH connection after install
  ssh_username = "ubuntu"
  ssh_password = "Aa123456"
  ssh_timeout  = "20m"
}

build {
  sources = ["source.proxmox-iso.ubuntu"]

  # Install your common packages
  provisioner "shell" {
    inline = [
      "sudo cloud-init clean",
      "sudo rm -rf /var/lib/cloud/*"
    ]
  }
}
