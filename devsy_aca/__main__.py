"""Entry point invoked by provider.yaml; stdout is reserved for Devsy."""
import argparse
import os
import sys
from pathlib import Path

from .provider import Config, Provider


def main():
    parser = argparse.ArgumentParser(description="Devsy provider for ACA Sandboxes")
    parser.add_argument("action", choices=["init", "create", "start", "stop", "status", "delete", "command"])
    args = parser.parse_args()
    try:
        # GUI SSH clients may start ProxyCommand without the login shell PATH.
        # AzureCliCredential locates `az` on PATH, so use the installer-selected
        # directory in this process only.
        if az_path := os.environ.get("ACA_AZ_CLI"):
            az = Path(az_path)
            if not (az.is_absolute() and az.name == "az" and az.is_file() and os.access(az, os.X_OK)):
                raise ValueError("ACA_AZ_CLI must be the absolute path of an executable named az")
            os.environ["PATH"] = str(az.parent) + os.pathsep + os.environ.get("PATH", os.defpath)
        provider = Provider(Config.from_env())
        if args.action == "init":
            provider.init()
            return 0
        machine_id = os.environ.get("MACHINE_ID") or os.environ.get("WORKSPACE_ID", "")
        if not machine_id:
            raise ValueError("MACHINE_ID is required (provided by Devsy)")
        if args.action == "command":
            command = os.environ.get("COMMAND", "")
            if not command:
                raise ValueError("COMMAND is required (provided by Devsy)")
            return provider.command(machine_id, command)
        result = getattr(provider, args.action)(machine_id)
        if args.action == "status":
            print(result)
        return 0
    except KeyboardInterrupt:
        return 130
    except Exception as exc:
        print(f"aca-sandboxes: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
