"""
Lab Operator — kopf-based controller.

Watches Lab CRDs and materializes them into namespaces full of VMs,
NetworkAttachmentDefinitions, and Services. Reconciles continuously,
handles TTL expiry, and cleans up cascading via owner references.

Run locally:
    python -m kopf run handler.py --verbose

Run in-cluster: see deploy/deployment.yaml.
"""

import hashlib
import logging
import os
from datetime import datetime

import kopf
import kubernetes

from lib import vlan_allocator, scenario_renderer, k8s, ttl

log = logging.getLogger("lab-operator")

CONFIG = {
    "registry": os.getenv("LAB_REGISTRY", "registry.lab.local"),
    "imageTag": os.getenv("LAB_IMAGE_TAG", "v1"),
}


# =============================================================================
# Startup / config
# =============================================================================

@kopf.on.startup()
def configure(settings: kopf.OperatorSettings, **_):
    """Tune kopf defaults for this controller."""
    settings.posting.level = logging.INFO
    settings.persistence.finalizer = "cyberrange.example.io/finalizer"
    settings.persistence.progress_storage = kopf.StatusProgressStorage()
    # Run reconcile every 30s minimum to refresh VM/Service status
    settings.scanning.disabled = False

    # Authenticate against the in-cluster API by default; fall back to ~/.kube/config
    try:
        kubernetes.config.load_incluster_config()
        log.info("Using in-cluster Kubernetes config")
    except kubernetes.config.ConfigException:
        kubernetes.config.load_kube_config()
        log.info("Using local Kubernetes config")


# =============================================================================
# Helpers
# =============================================================================

def make_namespace_name(lab_name: str, lab_uid: str) -> str:
    """Deterministic namespace name: lab-<name>-<8 hex chars of uid>."""
    suffix = hashlib.sha256(lab_uid.encode()).hexdigest()[:8]
    return f"lab-{lab_name}-{suffix}"


def transition_phase(patch, new_phase: str, reason: str = "") -> None:
    """Update Lab.status.phase with a logged transition."""
    log.info(f"phase -> {new_phase} ({reason})" if reason else f"phase -> {new_phase}")
    patch.status["phase"] = new_phase
    patch.status["lastReconcileTime"] = ttl.isoformat(ttl.now_utc())


def set_condition(patch, status, cond_type: str, status_str: str,
                  reason: str, message: str = "") -> None:
    """Set or update a condition on the Lab."""
    existing = list((status or {}).get("conditions") or [])
    now = ttl.isoformat(ttl.now_utc())
    for i, c in enumerate(existing):
        if c["type"] == cond_type:
            if c["status"] != status_str:
                c["lastTransitionTime"] = now
            c["status"] = status_str
            c["reason"] = reason
            c["message"] = message
            existing[i] = c
            patch.status["conditions"] = existing
            return
    existing.append({
        "type": cond_type,
        "status": status_str,
        "lastTransitionTime": now,
        "reason": reason,
        "message": message,
    })
    patch.status["conditions"] = existing


# =============================================================================
# Main reconciler — runs on create, update, and resume after operator restart
# =============================================================================

@kopf.on.create("cyberrange.example.io", "v1alpha1", "labs")
@kopf.on.resume("cyberrange.example.io", "v1alpha1", "labs")
def on_lab_create_or_resume(spec, status, name, body, patch, **_):
    """Materialize a new lab, or re-reconcile after operator restart."""
    log.info(f"Reconciling lab {name}")
    custom = kubernetes.client.CustomObjectsApi()

    # ---- 1. Validate scenario exists ------------------------------------
    scenario_name = spec["scenario"]
    try:
        scenario = scenario_renderer.lookup_scenario(custom, scenario_name)
    except kubernetes.client.ApiException as e:
        if e.status == 404:
            transition_phase(patch, "Failed", f"scenario {scenario_name} not found")
            set_condition(patch, status, "Ready", "False",
                          "ScenarioNotFound",
                          f"LabScenario '{scenario_name}' does not exist")
            raise kopf.PermanentError(f"Scenario {scenario_name} not found")
        raise

    # ---- 2. Allocate VLAN base (or reuse from status) -------------------
    try:
        vlan_base = vlan_allocator.ensure_vlan_base(
            custom, status or {}, spec.get("vlanBase")
        )
    except vlan_allocator.VLANExhausted as e:
        transition_phase(patch, "Pending", "all VLAN blocks in use")
        set_condition(patch, status, "Ready", "False", "VLANExhausted", str(e))
        raise kopf.TemporaryError("VLAN exhaustion; retrying", delay=60)

    patch.status["vlanBase"] = vlan_base

    # ---- 3. Compute namespace + expiry ----------------------------------
    namespace = make_namespace_name(name, body["metadata"]["uid"])
    patch.status["namespace"] = namespace
    patch.status["scenarioVersion"] = scenario["metadata"]["resourceVersion"]

    # ttl: spec override, scenario default, then hard default
    ttl_str = (
        spec.get("ttl")
        or (scenario["spec"].get("ttl") or {}).get("default")
        or "4h"
    )

    # startedAt is set once and preserved across reconciles
    started_at = (status or {}).get("startedAt")
    if not started_at:
        started_at = ttl.isoformat(ttl.now_utc())
        patch.status["startedAt"] = started_at
    expires_at = ttl.compute_expiry(ttl_str, ttl.parse_iso(started_at))
    patch.status["expiresAt"] = ttl.isoformat(expires_at)

    # ---- 4. Create namespace --------------------------------------------
    k8s.ensure_namespace(namespace, ttl_str, name)

    if (status or {}).get("phase") in (None, "Pending"):
        transition_phase(patch, "Provisioning", "creating resources")

    # ---- 5. Render & apply all resources --------------------------------
    manifests = scenario_renderer.render_lab(
        lab=body, scenario=scenario, namespace=namespace,
        vlan_base=vlan_base, config=CONFIG,
    )

    for manifest in manifests:
        k8s.set_owner_reference(manifest, body)
        try:
            k8s.apply_manifest(manifest, namespace)
        except Exception as e:
            log.exception(f"Failed to apply {manifest['kind']}/{manifest['metadata']['name']}")
            set_condition(patch, status, "Provisioned", "False",
                          "ApplyFailed", f"{manifest['kind']}: {e}")
            raise kopf.TemporaryError(f"Apply failed: {e}", delay=30)

    set_condition(patch, status, "Provisioned", "True", "AllResourcesCreated")
    set_condition(patch, status, "Networked", "True", "NADsApplied")

    # ---- 6. Reflect VM status into Lab.status ---------------------------
    vm_statuses, all_ready = read_vm_statuses(scenario, namespace)
    patch.status["vms"] = vm_statuses

    # ---- 7. Collect endpoint connection info ----------------------------
    endpoints = collect_endpoints(scenario, namespace)
    patch.status["endpoints"] = endpoints

    # ---- 8. Transition to Running once everything is ready --------------
    if all_ready and endpoints:
        transition_phase(patch, "Running", "all VMs ready")
        set_condition(patch, status, "Ready", "True", "AllVMsReady")
    elif (status or {}).get("phase") == "Running" and not all_ready:
        transition_phase(patch, "Degraded", "one or more VMs unhealthy")
        set_condition(patch, status, "Ready", "False", "VMsNotReady")
    else:
        # Still provisioning — kopf will requeue via timer
        raise kopf.TemporaryError("VMs still starting", delay=30)


def read_vm_statuses(scenario: dict, namespace: str) -> tuple[list[dict], bool]:
    """Pull VM phase from KubeVirt; return list of vmStatus dicts and a 'all ready' flag."""
    out = []
    all_ready = True
    for vm in scenario["spec"]["vms"]:
        st = k8s.get_vm_status(namespace, vm["name"]) or {}
        ready = (st.get("ready") is True) or (st.get("printableStatus") == "Running")
        if not ready:
            all_ready = False
        out.append({
            "name": vm["name"],
            "phase": st.get("printableStatus", "Pending"),
            "ready": bool(ready),
            "ip": (st.get("interfaces") or [{}])[0].get("ipAddress", ""),
        })
    return out, all_ready


def collect_endpoints(scenario: dict, namespace: str) -> dict:
    """Build {endpoint_name: 'node-ip:nodeport'} for all scenario endpoints."""
    node_ip = k8s.get_any_node_ip() or "<node-ip>"
    out = {}
    for ep in scenario["spec"].get("endpoints", []):
        port = k8s.get_service_nodeport(namespace, ep["name"])
        if port:
            out[ep["name"]] = f"{node_ip}:{port}"
    return out


# =============================================================================
# Periodic TTL check (also serves as a heartbeat reconciler)
# =============================================================================

@kopf.timer("cyberrange.example.io", "v1alpha1", "labs", interval=60)
def check_ttl(spec, status, name, body, patch, **_):
    """Every 60s: refresh VM status; if past expiry, start teardown."""
    if not status:
        return

    phase = status.get("phase")
    if phase in ("TearingDown", "Failed"):
        return

    expires = status.get("expiresAt")
    if expires and ttl.now_utc() >= ttl.parse_iso(expires):
        transition_phase(patch, "Expiring", "TTL exhausted")
        set_condition(patch, status, "Expiring", "True", "TTLExpired")
        ns = status.get("namespace")
        if ns:
            log.info(f"Deleting namespace {ns} for lab {name}")
            k8s.delete_namespace(ns)
        transition_phase(patch, "TearingDown")
        return

    # Heartbeat reconciliation while running
    if phase == "Running" and status.get("namespace"):
        # Re-read VM status; transition to Degraded if anything dropped
        try:
            custom = kubernetes.client.CustomObjectsApi()
            scenario = scenario_renderer.lookup_scenario(custom, spec["scenario"])
            vm_statuses, all_ready = read_vm_statuses(scenario, status["namespace"])
            patch.status["vms"] = vm_statuses
            patch.status["endpoints"] = collect_endpoints(scenario, status["namespace"])
            if not all_ready:
                transition_phase(patch, "Degraded", "VM unhealthy on heartbeat")
                set_condition(patch, status, "Ready", "False", "VMsNotReady")
        except Exception:
            log.exception("Heartbeat reconcile failed")


# =============================================================================
# Delete handler — owner references handle most cleanup, but we log + ack
# =============================================================================

@kopf.on.delete("cyberrange.example.io", "v1alpha1", "labs")
def on_lab_delete(name, status, **_):
    """Lab was deleted by user or by TTL teardown."""
    log.info(f"Lab {name} being deleted")
    ns = (status or {}).get("namespace")
    if ns:
        log.info(f"Ensuring namespace {ns} is deleted")
        k8s.delete_namespace(ns)
    # owner references on the namespace cascade-delete everything inside


# =============================================================================
# LabScenario validation (optional but useful)
# =============================================================================

@kopf.on.create("cyberrange.example.io", "v1alpha1", "labscenarios")
@kopf.on.update("cyberrange.example.io", "v1alpha1", "labscenarios")
def validate_scenario(spec, name, patch, **_):
    """Light validation of a LabScenario: bridges referenced are sane."""
    bridges_declared = set(spec.get("bridges") or [])
    for net in spec.get("networks", []):
        if net["bridge"] not in bridges_declared:
            patch.status.setdefault("conditions", []).append({
                "type": "Validated",
                "status": "False",
                "lastTransitionTime": ttl.isoformat(ttl.now_utc()),
                "reason": "UndeclaredBridge",
                "message": f"network {net['name']!r} uses bridge "
                           f"{net['bridge']!r} not in spec.bridges",
            })
            return

    offsets = [n["vlanOffset"] for n in spec.get("networks", [])]
    if len(offsets) != len(set(offsets)):
        patch.status.setdefault("conditions", []).append({
            "type": "Validated",
            "status": "False",
            "lastTransitionTime": ttl.isoformat(ttl.now_utc()),
            "reason": "DuplicateVlanOffset",
            "message": "vlanOffset values must be unique within a scenario",
        })
        return

    patch.status["vmCount"] = len(spec.get("vms") or [])
    patch.status["ready"] = True
    patch.status.setdefault("conditions", []).append({
        "type": "Validated",
        "status": "True",
        "lastTransitionTime": ttl.isoformat(ttl.now_utc()),
        "reason": "OK",
        "message": "scenario is structurally valid",
    })
