#####################
# Cloud config ansible controller #
#####################
resource "proxmox_virtual_environment_file" "ansible_controller_cloud_config" {
  count        = 3
  content_type = "snippets"
  datastore_id = "local"
  node_name    = "nucpve"

  source_raw {
    data = <<-EOF
    #cloud-config
    hostname: ansible-controller-${count.index + 1}
    timezone: Asia/Jerusalem
    users:
      - default
      - name: ubuntu
        groups:
          - sudo
        shell: /bin/bash
        ssh_authorized_keys:
          - ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIM78yhSDVwMquXXLBmoSL4RRx5M38Unn1hnMsGwjd2JM
        sudo: ALL=(ALL) NOPASSWD:ALL
        plain_text_passwd: Aa123456
        lock_passwd: false
    apt:
      proxy: http://192.168.2.117:3142/
    package_update: true
    package_upgrade: true
    packages:
      - curl
      - linux-generic
      - python3-pip
      - python3-venv
      - pipx
      - git
    write_files:
      - path: /home/ubuntu/.ssh/id_rsa
        owner: ubuntu:ubuntu
        permissions: '0600'
        encoding: b64
        content: ${base64encode(tls_private_key.vm_key.private_key_pem)}
    runcmd:
      - su - ubuntu -c "pipx install --include-deps ansible"
      - su - ubuntu -c "pipx ensurepath"
      - su - ubuntu -c "/home/ubuntu/.local/bin/ansible-galaxy collection install community.general"
      - echo "done" > /tmp/cloud-config.done
    EOF

    file_name = "ansible-controller-cloud-config-${count.index + 1}.yaml"
  }
}

#####################
# Cloud config control vm #
#####################
resource "proxmox_virtual_environment_file" "control_vm_cloud_config" {
  count        = var.control_count
  content_type = "snippets"
  datastore_id = "local"
  node_name    = "nucpve"

  source_raw {
    data = <<-EOF
    #cloud-config
    hostname: control-node-${count.index + 1}
    timezone: Asia/Jerusalem
    users:
      - default
      - name: ubuntu
        groups:
          - sudo
        shell: /bin/bash
        ssh_authorized_keys:
          - ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIM78yhSDVwMquXXLBmoSL4RRx5M38Unn1hnMsGwjd2JM
          - ${tls_private_key.vm_key.public_key_openssh}
        sudo: ALL=(ALL) NOPASSWD:ALL
        plain_text_passwd: Aa123456
        lock_passwd: false
    apt:
      proxy: http://192.168.2.117:3142/
    package_update: true
    package_upgrade: true
    packages:
      - curl
      - linux-generic
    runcmd:
      - su - ubuntu -c "pipx install --include-deps ansible"
      - su - ubuntu -c "pipx ensurepath"
      - su - ubuntu -c "/home/ubuntu/.local/bin/ansible-galaxy collection install community.general"
      - echo "done" > /tmp/cloud-config.done
    EOF

    file_name = "control-vm-cloud-config-${count.index + 1}.yaml"
  }
}


#####################
# Cloud config node vm #
#####################
resource "proxmox_virtual_environment_file" "node_vm_cloud_config" {
  count        = var.node_count 
  content_type = "snippets"
  datastore_id = "local"
  node_name    = "nucpve"

  source_raw {
    data = <<-EOF
    #cloud-config
    hostname: node-${count.index + 1}
    timezone: Asia/Jerusalem
    users:
      - default
      - name: ubuntu
        groups:
          - sudo
        shell: /bin/bash
        ssh_authorized_keys:
          - ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIM78yhSDVwMquXXLBmoSL4RRx5M38Unn1hnMsGwjd2JM
          - ${tls_private_key.vm_key.public_key_openssh}
        sudo: ALL=(ALL) NOPASSWD:ALL
        plain_text_passwd: Aa123456
        lock_passwd: false
    apt:
      proxy: http://192.168.2.117:3142/
    package_update: true
    package_upgrade: true
    packages:
      - curl
      - linux-generic
    runcmd:
      - echo "done" > /tmp/cloud-config.done
    EOF

    file_name = "node-vm-cloud-config-${count.index + 1}.yaml"
  }
}