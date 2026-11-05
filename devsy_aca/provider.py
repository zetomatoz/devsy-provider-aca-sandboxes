"""Devsy machine-provider lifecycle backed by ACA Sandbox resources."""
from __future__ import annotations

import hashlib
import os
import re
import shlex
import sys
from dataclasses import dataclass
from importlib.resources import files

from azure.containerapps.sandbox import EgressPolicy, SandboxGroupClient, endpoint_for_region
from azure.core.exceptions import ResourceNotFoundError
from azure.identity import AzureCliCredential

from .transport import run_command


@dataclass(frozen=True)
class Config:
    subscription_id: str
    resource_group: str = "rg-devsy-aca"
    sandbox_group: str = "devsy-sandboxes"
    location: str = "eastus2"
    disk: str = "ubuntu"
    cpu: str = "2000m"
    memory: str = "4096Mi"
    auto_suspend_seconds: int = 1800

    @classmethod
    def from_env(cls):
        subscription = os.environ.get("ACA_SUBSCRIPTION_ID", "")
        if not re.fullmatch(r"[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}", subscription):
            raise ValueError("ACA_SUBSCRIPTION_ID must be your Azure subscription UUID")
        values = {"subscription_id": subscription}
        for field, env in [("resource_group", "ACA_RESOURCE_GROUP"),
                           ("sandbox_group", "ACA_SANDBOX_GROUP"),
                           ("location", "ACA_LOCATION"), ("disk", "ACA_DISK"),
                           ("cpu", "ACA_CPU"), ("memory", "ACA_MEMORY")]:
            if os.environ.get(env):
                values[field] = os.environ[env]
        if "ACA_AUTO_SUSPEND_SECONDS" in os.environ:
            values["auto_suspend_seconds"] = int(os.environ["ACA_AUTO_SUSPEND_SECONDS"])
        config = cls(**values)
        if not re.fullmatch(r"[a-z0-9]+", config.location):
            raise ValueError("ACA_LOCATION must be a lowercase Azure region name")
        if config.auto_suspend_seconds < 60:
            raise ValueError("ACA_AUTO_SUSPEND_SECONDS must be at least 60")
        return config


def machine_label(machine_id: str) -> str:
    if not machine_id:
        raise ValueError("MACHINE_ID is required (set by Devsy)")
    return hashlib.sha256(machine_id.encode()).hexdigest()[:32]


def devsy_status(state: str | None) -> str:
    state = (state or "").lower()
    if state == "running":
        return "Running"
    if state in {"stopped", "suspended", "idle"}:
        return "Stopped"
    if state in {"creating", "resuming", "stopping"}:
        return "Busy"
    if state == "deleting":
        return "NotFound"
    raise RuntimeError(f"Unexpected ACA sandbox state: {state!r}")


class Provider:
    def __init__(self, config: Config, client=None, credential=None):
        self.config = config
        # Deliberately use the subscription-scoped Azure CLI login rather than
        # accidentally selecting a different environment/service identity.
        self.credential = credential or AzureCliCredential(subscription=config.subscription_id)
        self.client = client or SandboxGroupClient(
            endpoint_for_region(config.location), self.credential,
            subscription_id=config.subscription_id,
            resource_group=config.resource_group,
            sandbox_group=config.sandbox_group,
        )

    def find(self, machine_id: str):
        matches = list(self.client.list_sandboxes(labels={"devsy-machine": machine_label(machine_id)}))
        active = [sandbox for sandbox in matches if (sandbox.state or "").lower() != "deleting"]
        if len(active) > 1:
            raise RuntimeError("Multiple sandboxes match this Devsy machine; refusing to pick one")
        return self.client.get_sandbox_client(active[0].id) if active else None

    def init(self):
        # Proves group and data-plane RBAC access without creating resources.
        next(iter(self.client.list_sandboxes()), None)

    def bootstrap(self, sandbox):
        script = files("devsy_aca").joinpath("bootstrap.sh").read_text()
        result = sandbox.exec("/bin/bash -c " + shlex.quote(script))
        if result.exit_code:
            if result.stdout:
                print(result.stdout, end="", file=sys.stderr)
            if result.stderr:
                print(result.stderr, end="", file=sys.stderr)
            raise RuntimeError(f"Sandbox Docker bootstrap failed with exit code {result.exit_code}")

    def create(self, machine_id: str):
        sandbox = self.find(machine_id)
        created = sandbox is None
        if created:
            sandbox = self.client.begin_create_sandbox(
                disk=self.config.disk, cpu=self.config.cpu, memory=self.config.memory,
                auto_suspend_seconds=self.config.auto_suspend_seconds,
                labels={"devsy-machine": machine_label(machine_id), "devsy-provider": "aca-sandboxes"},
                # Development tools pull from changing CDN endpoints. Egress is
                # deliberately Allow for this proof; ingress ports remain empty.
                egress_policy=EgressPolicy(default_action="Allow"), ports=[],
            ).result()
        else:
            sandbox.ensure_running()
        try:
            self.bootstrap(sandbox)
        except (Exception, KeyboardInterrupt):
            if created:
                # Devsy discards its local machine record if create fails.
                # Remove only the fresh allocation; never discard a resumed
                # workspace whose bootstrap failed.
                try:
                    sandbox.delete()
                except Exception as cleanup_error:
                    print(f"Could not roll back sandbox {sandbox.sandbox_id}: {cleanup_error}", file=sys.stderr)
            raise

    def status(self, machine_id: str):
        sandbox = self.find(machine_id)
        if sandbox is None:
            return "NotFound"
        try:
            return devsy_status(sandbox.get().state)
        except ResourceNotFoundError:
            return "NotFound"

    def start(self, machine_id: str):
        sandbox = self.find(machine_id)
        if sandbox is None:
            raise RuntimeError("Sandbox does not exist; create the Devsy workspace first")
        sandbox.ensure_running()
        self.bootstrap(sandbox)

    def stop(self, machine_id: str):
        sandbox = self.find(machine_id)
        if sandbox and devsy_status(sandbox.get().state) != "Stopped":
            sandbox.begin_stop().result()

    def delete(self, machine_id: str):
        sandbox = self.find(machine_id)
        if sandbox:
            sandbox.begin_delete().result()

    def command(self, machine_id: str, command: str):
        sandbox = self.find(machine_id)
        if sandbox is None:
            raise RuntimeError("Devsy sandbox was not found")
        sandbox.ensure_running()
        return run_command(self.config, sandbox.sandbox_id, self.credential, command)
