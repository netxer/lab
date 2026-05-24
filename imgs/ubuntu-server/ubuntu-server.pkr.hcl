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

variable "proxmox_ip" {
  type    = string
  default = "192.168.4.100"
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
        "while [ ! -f /var/lib/cloud/instance/boot-finished ]; do echo 'Waiting for cloud-init...'; sleep 1; done",

        # Config changes first
        "sudo sed -i 's/GRUB_CMDLINE_LINUX=\"\"/GRUB_CMDLINE_LINUX=\"net.ifnames=0 biosdevname=0\"/' /etc/default/grub",
        "sudo update-grub",
        "sudo rm -f /etc/netplan/00-installer-config.yaml",

        # Ensure cloud-init growpart works for LVM-based root
        "sudo tee /etc/cloud/cloud.cfg.d/99-growpart.cfg > /dev/null << 'EOF'\ngrowpart:\n  mode: auto\n  devices: ['/']\n  ignore_growroot_disabled: false\nresize_rootfs: true\nEOF",

        # Auto-login ubuntu user on VGA console (tty1) and serial console (ttyS0)
        "sudo mkdir -p /etc/systemd/system/getty@tty1.service.d /etc/systemd/system/serial-getty@ttyS0.service.d",
        "sudo tee /etc/systemd/system/getty@tty1.service.d/autologin.conf << 'EOF'\n[Service]\nExecStart=\nExecStart=-/sbin/agetty --autologin ubuntu --noclear %I $TERM\nEOF",
        "sudo tee /etc/systemd/system/serial-getty@ttyS0.service.d/autologin.conf << 'EOF'\n[Service]\nExecStart=\nExecStart=-/sbin/agetty --autologin ubuntu --keep-baud 115200,57600,38400,9600 %I $TERM\nEOF",

        # Cleanup last
        "sudo rm -f /var/lib/dhcp/*.leases",
        "sudo rm -f /var/lib/dhcp/*.leases~",
        "sudo cloud-init clean --logs",
        "sudo rm -f /etc/cloud/cloud-init.disabled",
        "sudo rm -f /etc/netplan/50-cloud-init.yaml",
        "sudo truncate -s 0 /etc/machine-id",
        "sudo rm -f /var/lib/dbus/machine-id",
        "sudo sync"
      ]
    }
    provisioner "shell-local" {
      inline = [
        "ssh -o StrictHostKeyChecking=no root@${var.proxmox_ip} 'qemu-img convert -f raw -O qcow2 /dev/pve/vm-${build.ID}-disk-0 /tmp/ubuntu-template.qcow2'",
        "ssh -o StrictHostKeyChecking=no root@${var.proxmox_ip} 'cp /tmp/ubuntu-template.qcow2 /var/lib/vz/import/ubuntu-template.qcow2'",
        "ssh -o StrictHostKeyChecking=no root@${var.proxmox_ip} 'cp /tmp/ubuntu-template.qcow2 /mnt/pve/backup/import/ubuntu-template.qcow2'",
        "ssh -o StrictHostKeyChecking=no root@${var.proxmox_ip} 'rm -f /tmp/ubuntu-template.qcow2'"
        ]
    }
  }
