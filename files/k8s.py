"""
Kubernetes API helpers.

Thin wrappers around the kubernetes client to apply arbitrary manifests
and set owner references so deletion cascades cleanly.
"""

from typing import Any, Optional
import kubernetes
import logging

log = logging.getLogger("lab-operator.k8s")


def set_owner_reference(manifest: dict, owner: dict) -> None:
    """Add an ownerReference to a manifest, pointing at the owner Lab."""
    owner_ref = {
        "apiVersion": owner["apiVersion"],
        "kind": owner["kind"],
        "name": owner["metadata"]["name"],
        "uid": owner["metadata"]["uid"],
        "controller": True,
        "blockOwnerDeletion": True,
    }
    manifest.setdefault("metadata", {})
    manifest["metadata"].setdefault("ownerReferences", []).append(owner_ref)


def _parse_api(api_version: str) -> tuple[str, str]:
    """'apps/v1' -> ('apps', 'v1'); 'v1' -> ('', 'v1')."""
    parts = api_version.split("/")
    if len(parts) == 1:
        return "", parts[0]
    return parts[0], parts[1]


def apply_manifest(manifest: dict, namespace: str) -> None:
    """
    Apply a manifest, creating or updating as needed.

    Recognizes core types (Service, PVC) and CRDs (VirtualMachine, NAD,
    DataVolume). For unknown kinds, falls back to the dynamic client.
    """
    api_group, api_version = _parse_api(manifest["apiVersion"])
    kind = manifest["kind"]

    # Ensure metadata.namespace is set
    manifest.setdefault("metadata", {})["namespace"] = namespace

    if api_group == "":
        _apply_core(manifest, namespace, kind, api_version)
    elif api_group == "k8s.cni.cncf.io":
        _apply_custom(manifest, namespace, group=api_group,
                      version=api_version, plural="network-attachment-definitions")
    elif api_group == "kubevirt.io":
        plural = {"VirtualMachine": "virtualmachines"}.get(kind)
        if not plural:
            raise ValueError(f"Unknown kubevirt.io kind: {kind}")
        _apply_custom(manifest, namespace, group=api_group,
                      version=api_version, plural=plural)
    elif api_group == "cdi.kubevirt.io":
        _apply_custom(manifest, namespace, group=api_group,
                      version=api_version, plural="datavolumes")
    else:
        raise ValueError(f"Unsupported apiVersion: {manifest['apiVersion']}")


def _apply_core(manifest: dict, namespace: str, kind: str, version: str) -> None:
    """Apply core/v1 resources (Service, PVC, etc.)."""
    core = kubernetes.client.CoreV1Api()
    name = manifest["metadata"]["name"]

    handlers = {
        "Service": (core.read_namespaced_service,
                    core.create_namespaced_service,
                    core.patch_namespaced_service),
        "PersistentVolumeClaim": (core.read_namespaced_persistent_volume_claim,
                                   core.create_namespaced_persistent_volume_claim,
                                   core.patch_namespaced_persistent_volume_claim),
        "ConfigMap": (core.read_namespaced_config_map,
                      core.create_namespaced_config_map,
                      core.patch_namespaced_config_map),
        "Secret": (core.read_namespaced_secret,
                   core.create_namespaced_secret,
                   core.patch_namespaced_secret),
    }

    if kind not in handlers:
        raise ValueError(f"Unsupported core kind: {kind}")

    read, create, patch = handlers[kind]
    try:
        read(name=name, namespace=namespace)
        log.debug(f"Patching {kind}/{name} in {namespace}")
        patch(name=name, namespace=namespace, body=manifest)
    except kubernetes.client.ApiException as e:
        if e.status == 404:
            log.debug(f"Creating {kind}/{name} in {namespace}")
            create(namespace=namespace, body=manifest)
        else:
            raise


def _apply_custom(manifest: dict, namespace: str, group: str,
                  version: str, plural: str) -> None:
    """Apply a CRD-managed resource via the custom objects API."""
    custom = kubernetes.client.CustomObjectsApi()
    name = manifest["metadata"]["name"]

    try:
        custom.get_namespaced_custom_object(
            group=group, version=version, namespace=namespace,
            plural=plural, name=name,
        )
        log.debug(f"Patching {plural}/{name} in {namespace}")
        custom.patch_namespaced_custom_object(
            group=group, version=version, namespace=namespace,
            plural=plural, name=name, body=manifest,
        )
    except kubernetes.client.ApiException as e:
        if e.status == 404:
            log.debug(f"Creating {plural}/{name} in {namespace}")
            custom.create_namespaced_custom_object(
                group=group, version=version, namespace=namespace,
                plural=plural, body=manifest,
            )
        else:
            raise


def ensure_namespace(name: str, ttl: str, lab_name: str) -> None:
    """Create the lab namespace with TTL annotation if it doesn't exist."""
    core = kubernetes.client.CoreV1Api()
    try:
        core.read_namespace(name=name)
        # Already exists; ensure annotation is set
        core.patch_namespace(name=name, body={
            "metadata": {
                "annotations": {"janitor/ttl": ttl},
                "labels": {"app": "lab", "lab-name": lab_name},
            }
        })
    except kubernetes.client.ApiException as e:
        if e.status != 404:
            raise
        core.create_namespace(body={
            "apiVersion": "v1",
            "kind": "Namespace",
            "metadata": {
                "name": name,
                "annotations": {"janitor/ttl": ttl},
                "labels": {"app": "lab", "lab-name": lab_name},
            }
        })


def delete_namespace(name: str) -> None:
    """Delete the lab namespace (cascades via owner references)."""
    core = kubernetes.client.CoreV1Api()
    try:
        core.delete_namespace(name=name)
    except kubernetes.client.ApiException as e:
        if e.status != 404:
            raise


def get_vm_status(namespace: str, vm_name: str) -> Optional[dict]:
    """Read a VM's status (returns None if not found)."""
    custom = kubernetes.client.CustomObjectsApi()
    try:
        vm = custom.get_namespaced_custom_object(
            group="kubevirt.io", version="v1", namespace=namespace,
            plural="virtualmachines", name=vm_name,
        )
        return vm.get("status")
    except kubernetes.client.ApiException as e:
        if e.status == 404:
            return None
        raise


def get_service_nodeport(namespace: str, service_name: str) -> Optional[int]:
    """Read the assigned NodePort from a Service. Returns None if not ready."""
    core = kubernetes.client.CoreV1Api()
    try:
        svc = core.read_namespaced_service(name=service_name, namespace=namespace)
        if svc.spec.ports:
            return svc.spec.ports[0].node_port
    except kubernetes.client.ApiException as e:
        if e.status != 404:
            raise
    return None


def get_any_node_ip() -> Optional[str]:
    """Best-effort: return the InternalIP of any Ready lab node."""
    core = kubernetes.client.CoreV1Api()
    nodes = core.list_node(label_selector="lab-node=true")
    for node in nodes.items:
        for addr in (node.status.addresses or []):
            if addr.type == "InternalIP":
                return addr.address
    return None
