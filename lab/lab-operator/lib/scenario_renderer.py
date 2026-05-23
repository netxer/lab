"""
Scenario renderer.

Reads a LabScenario, combines it with a Lab's spec, and produces the list
of Kubernetes manifests that need to be applied (NADs, VMs, Services).

Templates live in templates/ as Jinja2 .j2 files. The scenario's `cloudInit`
content is also rendered through Jinja2 with the Lab's trainee values.

We accept both Go-template style (`{{ .Trainee.Name }}`) and Jinja2 style
(`{{ Trainee.Name }}`) by stripping leading dots before passing to Jinja2.
"""

from pathlib import Path
import re
from typing import Any

import jinja2

TEMPLATE_DIR = Path(__file__).parent.parent / "templates"
_env = jinja2.Environment(
    loader=jinja2.FileSystemLoader(str(TEMPLATE_DIR)),
    undefined=jinja2.StrictUndefined,
    autoescape=False,
    trim_blocks=True,
    lstrip_blocks=True,
)


def _normalize_go_template(s: str) -> str:
    """Strip leading dots from {{ .X }} → {{ X }} so Jinja2 can parse it."""
    return re.sub(r"\{\{\s*\.([A-Za-z_])", r"{{ \1", s)


def _render_string(template: str, ctx: dict) -> str:
    """Render an inline string template with the given context."""
    tmpl = _env.from_string(_normalize_go_template(template))
    return tmpl.render(**ctx)


def _file(name: str, ctx: dict) -> dict:
    """Render a templates/*.j2 file and parse as YAML."""
    import yaml
    tmpl = _env.get_template(name)
    rendered = tmpl.render(**ctx)
    return yaml.safe_load(rendered)


def render_lab(
    lab: dict,
    scenario: dict,
    namespace: str,
    vlan_base: int,
    config: dict,
) -> list[dict]:
    """
    Produce the full list of resources to apply for a Lab.

    Args:
        lab: the Lab custom resource as dict
        scenario: the LabScenario referenced by the Lab
        namespace: the target namespace name (already created elsewhere)
        vlan_base: the allocated VLAN base
        config: cluster-wide config (registry URL, image tags, etc.)

    Returns:
        list of manifests (dicts) ready to apply
    """
    spec = lab["spec"]
    scenario_spec = scenario["spec"]
    trainee = spec["trainee"]

    # Build the rendering context
    ctx: dict[str, Any] = {
        "Lab": {
            "Name": lab["metadata"]["name"],
            "UID": lab["metadata"]["uid"],
            "Namespace": namespace,
        },
        "Trainee": {
            "Name": trainee["name"],
            "SshPubKey": trainee["sshPubKey"],
        },
        "Registry": config.get("registry", "registry.lab.local"),
        "ImageTag": config.get("imageTag", "v1"),
        "VLANBase": vlan_base,
        # Networks resolved for easy lookup by name
        "Networks": {
            n["name"]: {**n, "vlan": vlan_base + n["vlanOffset"]}
            for n in scenario_spec["networks"]
        },
        "NodeSelector": spec.get("nodeSelector") or {"lab-node": "true"},
    }

    # Apply user resource overrides on top of scenario defaults
    resource_overrides = spec.get("resources") or {}
    defaults = scenario_spec.get("defaultResources") or {}

    def vm_resources(vm: dict) -> dict:
        name = vm["name"]
        override = resource_overrides.get(name) or {}
        default = defaults.get(name) or {}
        return {
            "cpu": override.get("cpu") or vm.get("cpu") or default.get("cpu") or 2,
            "memory": override.get("memory")
            or vm.get("memory")
            or default.get("memory")
            or "2Gi",
        }

    manifests: list[dict] = []

    # ---- NetworkAttachmentDefinitions -----------------------------------
    for net in scenario_spec["networks"]:
        manifests.append(
            _file(
                "nad.yaml.j2",
                {**ctx, "Net": {**net, "vlan": vlan_base + net["vlanOffset"]}},
            )
        )

    # ---- VirtualMachines ------------------------------------------------
    for vm in scenario_spec["vms"]:
        res = vm_resources(vm)
        vm_ctx = {**ctx, "VM": vm, "VMResources": res}

        # Render cloud-init inline if present
        ci = vm.get("cloudInit") or {}
        rendered_ci = {
            "userData": _render_string(ci.get("userData", ""), ctx) if ci.get("userData") else None,
            "networkData": _render_string(ci.get("networkData", ""), ctx) if ci.get("networkData") else None,
        }
        vm_ctx["RenderedCloudInit"] = rendered_ci

        # Pick the right template per disk strategy
        if vm["diskStrategy"] == "containerDisk":
            manifests.append(_file("vm-containerdisk.yaml.j2", vm_ctx))
        elif vm["diskStrategy"] == "dataVolumeClone":
            manifests.append(_file("vm-datavolume.yaml.j2", vm_ctx))
        else:
            raise ValueError(f"Unknown diskStrategy: {vm['diskStrategy']}")

    # ---- Services -------------------------------------------------------
    for ep in scenario_spec.get("endpoints", []):
        manifests.append(_file("service.yaml.j2", {**ctx, "Endpoint": ep}))

    return manifests


def lookup_scenario(
    custom_api,
    name: str,
) -> dict:
    """Fetch a LabScenario by name. Raises if not found."""
    return custom_api.get_cluster_custom_object(
        group="cyberrange.example.io",
        version="v1alpha1",
        plural="labscenarios",
        name=name,
    )
