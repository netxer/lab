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
          - ${tls_private_key.vm_key.public_key_openssh}
        sudo: ALL=(ALL) NOPASSWD:ALL
        plain_text_passwd: Aa123456
        lock_passwd: false
    write_files:
      - path: /home/ubuntu/.ssh/id_rsa
        owner: ubuntu:ubuntu
        permissions: '0600'
        encoding: b64
        content: ${base64encode(tls_private_key.vm_key.private_key_pem)}
      - path: /etc/apt/apt.conf.d/80-retries
        content: |
          Acquire::Retries "10";
          Acquire::http::Timeout "60";
          Acquire::https::Timeout "60";
        permissions: '0644'
    runcmd:
      - sleep ${count.index * 60}
      - apt-get update -y
      - apt-get upgrade -y
      - apt-get install -y curl linux-generic python3-pip python3-venv pipx git
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
    write_files:
      - path: /etc/apt/apt.conf.d/80-retries
        content: |
          Acquire::Retries "10";
          Acquire::http::Timeout "60";
          Acquire::https::Timeout "60";
        permissions: '0644'
    runcmd:
      - sleep ${count.index * 60 + 180}
      - apt-get update -y
      - apt-get upgrade -y
      - apt-get install -y curl linux-generic pipx
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
    write_files:
      - path: /etc/apt/apt.conf.d/80-retries
        content: |
          Acquire::Retries "10";
          Acquire::http::Timeout "60";
          Acquire::https::Timeout "60";
        permissions: '0644'
    runcmd:
      - sleep ${count.index * 60 + 360}
      - apt-get update -y
      - apt-get upgrade -y
      - apt-get install -y curl linux-generic
      - echo "done" > /tmp/cloud-config.done
    EOF

    file_name = "node-vm-cloud-config-${count.index + 1}.yaml"
  }
}
