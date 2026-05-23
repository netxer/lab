"""
VLAN block allocator.

Each Lab gets a unique 100-wide VLAN block (e.g. 100-199, 200-299, ...).
Scenarios use the block's base + their network's vlanOffset.

We persist the allocation in Lab.status.vlanBase. The allocator queries
existing Labs (not NADs) so allocation is per-Lab, not per-NAD — simpler
and avoids races when a Lab has multiple NADs.
"""

from typing import Iterable, Optional
import kubernetes

VLAN_BLOCK_SIZE = 100
VLAN_MIN = 100
VLAN_MAX = 4000


class VLANExhausted(Exception):
    """All VLAN blocks in [VLAN_MIN, VLAN_MAX) are in use."""


def allocate_vlan_base(existing_labs: Iterable[dict]) -> int:
    """
    Find the lowest free 100-block by scanning the provided Lab list.

    Args:
        existing_labs: iterable of Lab dicts (typically from list_labs())

    Returns:
        VLAN base (multiple of 100)

    Raises:
        VLANExhausted if no block is free
    """
    used: set[int] = set()
    for lab in existing_labs:
        status = lab.get("status") or {}
        vb = status.get("vlanBase")
        if isinstance(vb, int):
            used.add(vb)

    for candidate in range(VLAN_MIN, VLAN_MAX, VLAN_BLOCK_SIZE):
        if candidate not in used:
            return candidate

    raise VLANExhausted(
        f"All VLAN blocks in [{VLAN_MIN}, {VLAN_MAX}) are in use "
        f"({len(used)} labs running)"
    )


def list_labs(custom_api: kubernetes.client.CustomObjectsApi) -> list[dict]:
    """Fetch all Lab resources from the cluster."""
    result = custom_api.list_cluster_custom_object(
        group="cyberrange.example.io",
        version="v1alpha1",
        plural="labs",
    )
    return result.get("items", [])


def ensure_vlan_base(
    custom_api: kubernetes.client.CustomObjectsApi,
    lab_status: dict,
    requested: Optional[int],
) -> int:
    """
    Return a VLAN base for this Lab, allocating if needed.

    If status.vlanBase is already set, use that (idempotent on retries).
    If spec.vlanBase is set explicitly, validate and use it.
    Otherwise auto-allocate.
    """
    existing = lab_status.get("vlanBase")
    if isinstance(existing, int):
        return existing

    if requested is not None:
        # Operator trusts the user but still bounds-checks
        if not (VLAN_MIN <= requested < VLAN_MAX):
            raise ValueError(
                f"vlanBase {requested} out of range [{VLAN_MIN}, {VLAN_MAX})"
            )
        if requested % VLAN_BLOCK_SIZE != 0:
            raise ValueError(
                f"vlanBase {requested} must be a multiple of {VLAN_BLOCK_SIZE}"
            )
        # Double-check it's not already used by another Lab
        used = {
            (lab.get("status") or {}).get("vlanBase")
            for lab in list_labs(custom_api)
        }
        used.discard(None)
        if requested in used:
            raise ValueError(f"vlanBase {requested} already used by another lab")
        return requested

    return allocate_vlan_base(list_labs(custom_api))
