# Lab Operator

A kopf-based Kubernetes controller that watches `Lab` CRDs and materializes them into a complete disposable cyber-range lab — namespace + NADs + VMs + Services + TTL.

## What it does

For every `Lab` resource the operator:

1. **Validates** the referenced `LabScenario` exists.
2. **Allocates a VLAN base** (auto-picks a free 100-block, or honors `spec.vlanBase`).
3. **Creates a namespace** named `lab-<trainee>-<uid-hash>` with a `janitor/ttl` annotation.
4. **Renders the scenario** through Jinja2: NADs, VMs (containerDisk and dataVolumeClone), Services.
5. **Applies everything** with owner references pointing at the Lab.
6. **Updates `status`** — phase, allocated VLAN, VM readiness, endpoint addresses, expiry.
7. **Watches continuously**: refreshes status every 60 s, transitions to `Degraded` if a VM dies.
8. **Sweeps on TTL expiry**: deletes the namespace, which cascades through owner refs.

Phases (per the spec): `Pending` → `Provisioning` → `Running` → (`Degraded` ↔ `Running`) → `Expiring` → `TearingDown`.

## File layout

```
lab-operator/
├── README.md                  # this file
├── Dockerfile
├── requirements.txt
├── handler.py                 # kopf entrypoint, all the lifecycle handlers
├── lib/
│   ├── __init__.py
│   ├── vlan_allocator.py      # picks free VLAN blocks
│   ├── scenario_renderer.py   # Jinja-renders LabScenario into manifests
│   ├── k8s.py                 # K8s API helpers (apply, owner refs, status reads)
│   └── ttl.py                 # duration parsing + ISO timestamps
├── templates/
│   ├── nad.yaml.j2            # NetworkAttachmentDefinition
│   ├── vm-containerdisk.yaml.j2
│   ├── vm-datavolume.yaml.j2  # for Windows + golden PVC clones
│   └── service.yaml.j2
└── deploy/
    └── deployment.yaml        # in-cluster Deployment + Namespace
```

RBAC for the operator lives in the separate `lab-crd/rbac/operator-rbac.yaml` — apply that first.

## Local development

You can run the operator against a kubeconfig-accessible cluster directly:

```bash
python -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt

# Install the CRDs and a sample scenario first
kubectl apply -f ../lab-crd/crds/
kubectl apply -f ../lab-crd/examples/scenarios/corporate-ad.yaml

# Run the operator (uses ~/.kube/config when not in-cluster)
kopf run --standalone handler.py --verbose
```

In another terminal:

```bash
kubectl apply -f ../lab-crd/examples/lab-example.yaml
kubectl get labs -w
```

You'll see the lab progress through `Provisioning` → `Running` as the namespace fills with VMs.

## In-cluster deployment

```bash
# 1) Install CRDs + RBAC + scenarios (one-time per cluster)
kubectl apply -f ../lab-crd/crds/
kubectl apply -f ../lab-crd/rbac/
kubectl apply -f ../lab-crd/examples/scenarios/

# 2) Build & push the operator image
docker build -t registry.lab.local/lab-operator:v0.1.0 .
docker push  registry.lab.local/lab-operator:v0.1.0

# 3) Deploy
kubectl apply -f deploy/deployment.yaml
kubectl logs -n lab-operator-system deploy/lab-operator -f
```

## Configuration

Environment variables on the Deployment:

| Var | Default | Purpose |
|---|---|---|
| `LAB_REGISTRY` | `registry.lab.local` | Substituted into `{{ Registry }}` in scenario image paths |
| `LAB_IMAGE_TAG` | `v1` | Substituted into `{{ ImageTag }}` |

Per-Lab overrides live in the Lab CRD (`spec.resources`, `spec.networkOverrides`, etc.) — see `../lab-crd/SPECIFICATION.md`.

## Template variables available to scenarios

Both Go-style (`{{ .Trainee.Name }}`) and Jinja-style (`{{ Trainee.Name }}`) work — the renderer strips leading dots before passing to Jinja2.

| Variable | Source |
|---|---|
| `Lab.Name` | `metadata.name` of the Lab |
| `Lab.UID` | `metadata.uid` of the Lab |
| `Lab.Namespace` | Generated namespace name |
| `Trainee.Name` | `spec.trainee.name` |
| `Trainee.SshPubKey` | `spec.trainee.sshPubKey` |
| `Registry` | From `LAB_REGISTRY` env |
| `ImageTag` | From `LAB_IMAGE_TAG` env |
| `VLANBase` | Allocated VLAN block base |
| `Networks.<name>` | Scenario network entry, with `.vlan` resolved |
| `NodeSelector` | `spec.nodeSelector` or `{lab-node: "true"}` |

## What this operator does NOT do

Deliberately out of scope — handled by other components:

- **TTL sweeping** of namespaces — `kube-janitor` does this. The operator only annotates.
- **Bridge creation** on nodes — `kubernetes-nmstate` does this via NNCPs.
- **Container registry** — install Harbor / Distribution separately.
- **Golden image building** — manual one-time process, see top-level `README.md`.
- **Admission webhooks** — optional, not implemented in this scaffold. Add later if validation latency matters.
- **Metrics** — recommend wrapping with a Prometheus exporter; kopf has built-in metrics.

## Known caveats of this scaffold

This is starting code, not battle-tested. Areas worth attention before production use:

- **Concurrent VLAN allocation**: two Labs created in the same instant could both grab the same block. Either run a single replica (current default), use leader election (kopf supports it), or move VLAN allocation behind an admission webhook.
- **Manifest application is not strictly server-side-apply**: uses get-or-create then patch. Replace with SSA (`apply --field-manager`) for cleaner ownership.
- **Owner references rely on the namespace's lifecycle**: deletion cascades through the namespace's ownerRef, not direct refs from the Lab to inner resources. This is intentional but worth knowing — if you ever want to keep the namespace and just rebuild contents, you'd need to refactor.
- **Cloud-init rendering uses StrictUndefined**: any missing variable in a scenario template fails loudly. Good for catching bugs, but expect to fix scenarios when you find them.
- **No retries on transient K8s API errors** beyond what kopf's `TemporaryError` provides. Consider tenacity for finer-grained backoff.
- **Status updates are eventually consistent**: the heartbeat is every 60 s, so VM transitions can take up to a minute to show in `kubectl get labs`. Lower `@kopf.timer(..., interval=...)` if you need faster.

## Testing the loop end-to-end

```bash
# Apply CRDs, scenarios, RBAC, deployment as above. Then:

cat <<EOF | kubectl apply -f -
apiVersion: cyberrange.example.io/v1alpha1
kind: Lab
metadata:
  name: smoketest
spec:
  scenario: corporate-ad
  trainee:
    name: smoketest
    sshPubKey: "$(cat ~/.ssh/id_ed25519.pub)"
  ttl: 30m
EOF

# Watch
kubectl get lab smoketest -w

# Inspect inside the lab namespace
NS=$(kubectl get lab smoketest -o jsonpath='{.status.namespace}')
kubectl get vm,svc,nad -n $NS

# Console into a VM
virtctl vnc pfsense -n $NS

# Trigger early teardown
kubectl delete lab smoketest
# Namespace should disappear within ~30s
```

## Extending

To add a new scenario type:
1. Write a new `LabScenario` YAML (see `../lab-crd/examples/scenarios/`).
2. `kubectl apply -f new-scenario.yaml`.
3. New Lab resources can reference it immediately. No operator rebuild needed.

To support a new VM disk strategy beyond `containerDisk` and `dataVolumeClone`:
1. Add a new value to the CRD's `vms[].diskStrategy` enum.
2. Add a new `templates/vm-*.yaml.j2` for the new shape.
3. Add a branch in `scenario_renderer.render_lab()`.

To support new resource kinds in scenarios (e.g. ConfigMaps):
1. Add a template in `templates/`.
2. Add a render step in `scenario_renderer.render_lab()`.
3. Add a handler branch in `k8s.apply_manifest()`.
