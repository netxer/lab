# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

Home lab IaC for a Proxmox VE cluster (`nucpve` at `192.168.4.100`). The workflow is two-stage: **Packer builds a base Ubuntu image**, then **OpenTofu provisions VMs** from that image.

## Commands

### Packer — build the Ubuntu base image

```bash
cd imgs/ubuntu-server
packer init .
packer build .
```

Credentials are read from `ubuntu-server.auto.pkrvars.json` (gitignored). The build produces `ubuntu-template.qcow2` copied directly to `/var/lib/vz/import/` on the Proxmox host via SSH.

### OpenTofu — provision VMs

```bash
cd tofu
tofu init
tofu plan
tofu apply
```

Credentials live in `vars.auto.tfvars` (gitignored). After `apply`, OpenTofu writes generated files to `../ansible/` (SSH key, inventory, test playbook) and SCPs them to the Ansible controller VM.

### Useful runtime commands

```bash
# SSH to Ansible controller (static IP)
ssh ubuntu@192.168.4.5 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null

# Check cloud-init status on a VM
sudo cloud-init status --long

# Run test playbook from Ansible controller
ansible-playbook -i ansible_inventory.ini test-connectivity.yml
```

## Architecture

### Packer (`imgs/ubuntu-server/`)

- `ubuntu-server.pkr.hcl` — builds an Ubuntu 26.04 VM template using `proxmox-iso` source; uses autoinstall via HTTP served from `http/`
- `http/user-data` — Ubuntu autoinstall config (packages, user, SSH, swap disabled)
- After install, a shell provisioner cleans cloud-init state so the image is clone-safe; a `shell-local` provisioner SSHes to Proxmox to convert and place the qcow2

### OpenTofu (`tofu/`)

- `main.tf` — provider config (`bpg/proxmox` + `filipowm/unifi`), imports the qcow2 as a Proxmox datastore file, generates a TLS key pair, and writes `../ansible/` files
- `vms.tf` — three VM resource types:
  - `ansible_controller` (count=1, static IP `192.168.4.5/24`)
  - `control_vm` (count=`var.control_count`, default 3, DHCP)
  - `node` (count=`var.node_count`, default 3, DHCP)
- `cloudinit.tf` — per-VM cloud-config snippets uploaded to Proxmox `local` datastore; ansible controller installs Ansible via `pipx` in `runcmd`
- `dns.tf` — creates A records in UniFi for all VMs under `*.lab.sinofage.com`
- `variables.tf` — all required variables; secrets are `sensitive = true`

### Key design decisions

- All VMs are cloned from the same `ubuntu-template.qcow2` image stored in the Proxmox `import` datastore on `local`
- SSH keys are Terraform-generated per `apply`; the private key is written to `../ansible/ansible_key.pem` (gitignored via `ansible_key*`)
- The Ansible controller receives both the generated private key (written to `/home/ubuntu/.ssh/id_rsa` via cloud-init) and the inventory/playbook files over SCP post-boot
- DNS is managed through the UniFi controller API, not a traditional DNS server
- `tofu/.terraform/` and state files are gitignored; the lock file (`.terraform.lock.hcl`) is committed