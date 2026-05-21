# Kubernetes Cyber Range Lab

A fully autonomous, operator-driven cyber-range platform on Kubernetes. Trainees get disposable labs via a single `kubectl apply`. No scripts, no per-node SSH, no manual orchestration after bootstrap.

**Target environment:** K3s cluster on Proxmox VMs, provisioned with Terraform, configured with Ansible. Operators handle everything inside the cluster.

---

## User Interface

```bash
# Spawn a lab
kubectl apply -f - <<EOF
apiVersion: cyberrange.example.io/v1
kind: Lab
metadata:
  name: alice-corporate
spec:
  scenario: corporate-ad
  trainee:
    name: alice
    sshPubKey: "ssh-ed25519 AAAA..."
  ttl: 4h
EOF

# Status & connection details
kubectl get lab alice-corporate -o jsonpath='{.status.endpoints}'

# Tear down (cascades cleanup)
kubectl delete lab alice-corporate
```

The Lab controller watches these resources and materializes everything: namespace, NADs (with auto-allocated VLAN IDs), pfSense + workstation VMs, NodePort Services, TTL sweep.

---

## Layered Architecture

```
┌─────────────────────────────────────────────────────────┐
│ Layer 4 — User                                          │
│   kubectl apply / delete on Lab resources               │
├─────────────────────────────────────────────────────────┤
│ Layer 3 — Lab Operator (custom, kopf or operator-sdk)   │
│   Watches Lab CRDs                                      │
│   Creates: namespace, NADs, VMs, Services               │
│   Auto-allocates VLAN IDs across labs                   │
│   Enforces TTL & cascading cleanup                      │
├─────────────────────────────────────────────────────────┤
│ Layer 2 — Cluster State (declarative YAML in git)       │
│   HyperConverged CR (turns the stack on)                │
│   NodeNetworkConfigurationPolicy (VLAN-aware bridges)   │
│   NodeFeatureDiscovery rules (auto-label lab nodes)     │
│   kube-janitor (TTL sweeper)                            │
│   In-cluster container registry                         │
│   Golden image PVCs in `lab-templates` namespace        │
├─────────────────────────────────────────────────────────┤
│ Layer 1 — Platform Operators (one bundle: HCO)          │
│   KubeVirt   — VMs as K8s resources                     │
│   CDI        — disk imports & cloning                   │
│   CNAO       — Multus + Bridge CNI + KubeMacPool        │
│   NMState    — declarative host networking              │
├─────────────────────────────────────────────────────────┤
│ Layer 0 — Kubernetes (K3s)                              │
├─────────────────────────────────────────────────────────┤
│ Layer -1 — Infrastructure (managed externally)          │
│   Terraform → Proxmox VMs                               │
│   Ansible   → OS prep + K3s install                     │
└─────────────────────────────────────────────────────────┘
```

Layers 0 and -1 are handled by your existing Proxmox/Terraform/Ansible pipeline. Layers 1-3 are pure `kubectl apply`. Layer 4 is the user.

Operators reconcile continuously — adding a node = it picks up bridges, KVM access, and labels automatically. Self-healing on reboots and drift.

---

## Network Topology Inside Each Lab

```
                          Internet
                             │
                    ┌────────┴────────┐
                    │   Pod Network   │
                    └───┬─────────┬───┘
                        │         │
                  pfSense WAN     │
                        │         │
                  ┌─────┴─────┐   │
                  │  pfSense  │   │
                  └─┬───┬───┬─┘   │
                    │   │   │     │
              br-lan │   │   │ br-observer
                    │   │   │     │
              ┌─────┘   │   └─────┼─────┐
              │     br-dmz        │     │
              │         │         │     │
        ┌─────┴───┐ ┌───┴────┐    │  ┌──┴──────────┐
        │ Win 11  │ │ Web    │    │  │ Trainee VM  │
        │ AD / DC │ │ server │    └──┤ NIC1 = OBS  │
        └─────────┘ └────────┘       │ NIC2 = NET  │
                                     └─────────────┘
```

Per-lab VLAN tagging isolates Alice/Bob/Carol from each other on shared bridges. Same IPs (10.10.10.0/24 etc.) reused across labs — no collisions.

| VM | Disk strategy | Networks |
|---|---|---|
| pfSense | containerDisk (ephemeral) | WAN (pod), LAN, DMZ, OBS |
| AD/DC (Windows Server) | DataVolume clone of `dc-golden` | LAN |
| Win11 client | DataVolume clone of `win11-golden` | LAN |
| Trainee (Ubuntu/Kali) | containerDisk (ephemeral) | OBS + pod network (dual-homed) |

---

## The Operator Stack

| Operator | Role | Source |
|---|---|---|
| **HCO** | Single CR enables the whole platform; bundles the four below | kubevirt/hyperconverged-cluster-operator |
| **KubeVirt** | `VirtualMachine` / `VirtualMachineInstance` CRDs | kubevirt/kubevirt |
| **CDI** | `DataVolume` CRD: disk imports, golden cloning | kubevirt/containerized-data-importer |
| **CNAO** | Multus, Bridge CNI, KubeMacPool, bridge-marker | kubevirt/cluster-network-addons-operator |
| **kubernetes-nmstate** | `NodeNetworkConfigurationPolicy`: bridges, VLANs, routes | nmstate/kubernetes-nmstate |
| **NFD** | Auto-labels nodes by hardware (KVM, VT-x, GPU) | kubernetes-sigs/node-feature-discovery |
| **kube-janitor** | TTL sweep of expired lab namespaces | hjacobs/kube-janitor |
| **Lab Operator** (custom) | `Lab` CRD: materializes labs end-to-end | (write your own — kopf recommended) |

---

## The Lab CRD

```yaml
apiVersion: cyberrange.example.io/v1
kind: Lab
metadata:
  name: alice-corporate
spec:
  scenario: corporate-ad        # name of a scenario template in the operator
  trainee:
    name: alice
    sshPubKey: "ssh-ed25519 AAAA..."
  ttl: 4h                       # operator annotates namespace for kube-janitor
  resources:                    # optional overrides
    cpu: 8
    memory: 16Gi
status:
  phase: Running                # Pending | Building | Running | TearingDown
  namespace: lab-alice-20260520-1430
  vlanBase: 200                 # operator-allocated
  endpoints:
    trainee-ssh: "node-ip:30501"
    trainee-rdp: "node-ip:30502"
  expiresAt: "2026-05-20T18:30:00Z"
```

---

## Bootstrap

### 1. Terraform — provision Proxmox VMs

Critical settings for nested virtualization:
- `cpu: "host"` (passes through VT-x/AMD-V)
- `args: "-cpu host,+vmx"` (Intel) or `+svm` (AMD)
- 4+ vCPU, 16+ GB RAM, 200+ GB disk per node
- Bridge interface on your management VLAN

Example with the Telmate provider:

```hcl
resource "proxmox_vm_qemu" "lab_node" {
  count       = 3
  name        = "lab-node-${count.index}"
  target_node = "pve01"
  iso         = "local:iso/ubuntu-22.04-server.iso"
  cores       = 4
  memory      = 16384
  cpu         = "host"
  args        = "-cpu host,+vmx"
  network {
    bridge = "vmbr0"
    model  = "virtio"
  }
  disk {
    type    = "scsi"
    storage = "local-lvm"
    size    = "200G"
  }
}
```

### 2. Ansible — OS prep + K3s

Idempotent playbook covering every lab node:

- `apt update` + base packages
- Load KVM module:
  ```yaml
  - name: Load kvm-intel
    community.general.modprobe:
      name: kvm-intel
      state: present
  - name: Persist kvm module load
    copy:
      content: "kvm-intel\n"
      dest: /etc/modules-load.d/kvm.conf
  ```
- Install K3s (first node as server, rest as agents)
- Drop kubeconfig on the workstation

After this: every node has `/dev/kvm`, K3s is up, `kubectl get nodes` works. That's the entire OS-level setup.

### 3. Cluster state — `kubectl apply -k cluster/`

```bash
git clone https://your-repo/cyber-range.git
cd cyber-range
kubectl apply -k cluster/
```

That single command brings up everything in Layers 1-3:

| Resource | What it does |
|---|---|
| HCO operator + HyperConverged CR | Installs KubeVirt, CDI, CNAO, NMState |
| NodeNetworkConfigurationPolicy | Creates `br-lan`, `br-dmz`, `br-observer` with `vlan_filtering=1` on every node |
| NodeFeatureDiscovery rules | Auto-labels nodes that have `vmx`/`svm` with `lab-node=true` |
| kube-janitor (via Helm) | TTL-based namespace sweeping |
| Container registry | In-cluster registry for containerDisk images |
| Lab CRD + Lab operator | Custom controller materializing lab resources |

Wait for settle:
```bash
kubectl wait --for=condition=Available \
  hco/kubevirt-hyperconverged \
  -n kubevirt-hyperconverged --timeout=15m
```

### Verification

```bash
kubectl get hco -A                                # platform up
kubectl get nncp                                  # bridge policies Available
kubectl get nns -o wide                           # node network state
kubectl get nodes -L lab-node                     # auto-labeled
kubectl get crd labs.cyberrange.example.io        # Lab CRD installed
kubectl apply -f examples/minimal-lab.yaml        # smoke test
kubectl get lab -w
```

---

## Adding / Removing Nodes

**Add:**
- Terraform: bump `count`, `terraform apply`
- Ansible: re-run the playbook (idempotent)
- Done. NMState makes bridges, NFD labels the node, KubeVirt agent comes up.

**Remove:**
```bash
kubectl drain <node>
kubectl delete node <node>
# then: terraform destroy -target=proxmox_vm_qemu.lab_node[N]
```

Operators clean up automatically.

---

## Golden Images (one-time, manual)

The only piece operators can't fully automate — Windows licensing, ISO selection, and OS installation need a human in the loop the first time.

**Ephemeral OS disks (pfSense, trainee Ubuntu/Kali):**
- Build once via a temporary VM
- Convert to qcow2
- Package as containerDisk OCI image
- Push to in-cluster registry
- Operator pulls on every lab start

**Persistent OS disks (Windows 11, AD/DC):**
- Install once into PVCs in `lab-templates` namespace using KubeVirt + CDI
- Operator clones via `DataVolume source: pvc` per lab

After this one-time build, the operator handles everything via clone-on-demand. Bumping base images is a re-build + push; new labs pick up the new version, running labs are unaffected.

---

## Repo Layout

```
cyber-range/
├── README.md                          # this file
├── terraform/                         # Proxmox VM provisioning
│   ├── main.tf
│   └── variables.tf
├── ansible/                           # OS prep + K3s install
│   ├── playbook.yml
│   ├── inventory.ini
│   └── roles/
├── cluster/                           # declarative cluster state
│   ├── kustomization.yaml
│   ├── 00-hco.yaml
│   ├── 01-hyperconverged-cr.yaml
│   ├── 02-bridges.nncp.yaml
│   ├── 03-nfd-rules.yaml
│   ├── 04-kube-janitor.yaml
│   ├── 05-registry.yaml
│   ├── 06-lab-crd.yaml
│   └── 07-lab-operator.yaml
├── lab-operator/                      # custom controller
│   ├── handler.py                     # kopf handler
│   ├── Dockerfile
│   └── scenarios/                     # per-scenario manifest templates
│       ├── corporate-ad/
│       ├── ics/
│       └── webapp/
├── lab-chart/                         # Helm chart the operator uses internally
│   ├── Chart.yaml
│   ├── values.yaml
│   └── templates/
└── examples/                          # sample Lab resources
    ├── alice-corporate.yaml
    ├── bob-ics.yaml
    └── minimal-lab.yaml
```

---

## Common Commands

```bash
# Labs
kubectl get labs -A                                 # all running labs
kubectl apply -f examples/alice-corporate.yaml      # spawn
kubectl get lab alice-corporate -w                  # watch progress
kubectl get lab alice-corporate \
  -o jsonpath='{.status.endpoints}'                 # connection details
kubectl delete lab alice-corporate                  # tear down

# Inspect a lab's materialized resources
NS=$(kubectl get lab alice-corporate -o jsonpath='{.status.namespace}')
kubectl get vm,svc,pvc -n $NS
virtctl vnc pfsense -n $NS                          # console into pfSense

# Platform health
kubectl get hco,nncp,nns -A
kubectl get nodes -L lab-node

# Render chart without deploying (debugging)
helm template alice ./lab-chart \
  --set trainee.name=alice --set vlanBase=200 | less

# Manual deploy via chart (fallback path, bypassing operator)
helm install alice ./lab-chart \
  -n lab-alice-$(date +%s) --create-namespace \
  --set trainee.name=alice --set vlanBase=200
```

---

## Gotchas

- **Nested virtualization**: Proxmox VMs must use `cpu: host` and have `+vmx`/`+svm` passed through. Without this, `/dev/kvm` won't exist and KubeVirt VMs won't schedule. Test with `egrep -c '(vmx|svm)' /proc/cpuinfo` on each node — must be > 0.
- **Windows 11 needs vTPM 2.0, UEFI + Secure Boot, and SMM CPU feature** — all set in the VM spec templates. Don't enable BitLocker without persistent TPM/EFI.
- **VirtIO drivers** during Windows install or the disk and NIC won't appear (handled by the golden-image build, not at lab spawn).
- **Trainee dual-NIC routing**: cloud-init sets `use-routes: false` on the lab NIC so the default route stays on the internet NIC. Verify with `ip route` inside the VM.
- **VLAN-aware bridges** need `vlan_filtering=1` — NMState handles this in the NNCP. Verify with `bridge -d link show`.
- **macvlan can't do same-node VM-to-VM** — bridge CNI only.
- **Bridges must exist on every lab-eligible node** — NMState makes them everywhere matching the policy's nodeSelector.
- **Operators can't fix BIOS settings** — VT-x/AMD-V must be on; if running nested, Proxmox host must also have nested virt enabled (`/sys/module/kvm_intel/parameters/nested` = `Y`).

---

## What's Manual, Total

After everything is in place:
- **Proxmox VM provisioning settings** → Terraform handles it
- **KVM kernel module + K3s install** → Ansible handles it
- **Cluster operators + cluster state** → `kubectl apply -k cluster/` once
- **Golden image building** → one-time, human in loop
- **Creating a lab** → `kubectl apply -f Lab.yaml`
- **Adding a node** → terraform apply + ansible playbook
- **Destroying a lab** → `kubectl delete lab` or wait for TTL

That's the autonomous endpoint.
