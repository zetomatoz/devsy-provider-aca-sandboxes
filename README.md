# Devsy on Azure Container Apps Sandboxes

A Python Devsy provider that provisions a Linux ACA sandbox, runs a Docker dev
container inside it, and connects through the authenticated Sandbox API over
HTTPS/WebSocket. No inbound SSH port or public sandbox app port is required.

[![Start the .NET workspace](https://img.shields.io/badge/Devsy-Start%20.NET%20workspace-512BD4?logo=dotnet&logoColor=white)](#start-the-workspace)

The button opens the launch instructions. A GitHub README cannot safely execute a
local CLI command; the executable launcher is `scripts/up.sh`.

Verified in Azure DEV: a .NET 10 workspace, the VS Code editor, and the Agents
window's remote Agent Host all ran through the Devsy proxy with no sandbox ports
exposed. Copilot built the app and passed both HTTP checks from the remote
workspace. See the [validation record](docs/validation.md).

## Start the workspace

Prerequisites: Python 3.10+, Azure CLI, the official `aca` CLI, Devsy, and VS Code.
Keep this checkout in a durable folder: the registered provider uses its Python
virtual environment by absolute path. macOS and Linux are the initial targets.

Install Devsy from its [official instructions](https://devsy.sh/docs/getting-started/install).
Install the separate ACA CLI from [Microsoft](https://github.com/microsoft/azure-container-apps/tree/main/aca-cli/preview):

```sh
curl -fsSL https://aka.ms/aca-cli-install | sh
aca --version
```

This same install path is also used inside sandboxes and containers for
agent-driven self-installs.

Authenticate to your Entra tenant and select your development subscription. If a
real token request succeeds, skip sign-in; `az account show` alone can return
stale cached account data.

```sh
az account get-access-token --resource https://management.azure.com --output none || az login
az account set --subscription YOUR_DEV_SUBSCRIPTION_ID
./scripts/up.sh
```

The launcher creates `rg-devsy-aca` and `devsy-sandboxes` in `eastus2`, grants the
signed-in user the sandbox Data Owner role on the new group, installs/registers
this provider, starts the included .NET example as `dotnet-aca`, and opens VS Code.
It leaves an existing Devsy default provider selected. Provisioning resources and
running sandboxes incur Azure charges; suspend preserves state and still uses
storage.

Override infrastructure defaults with `ACA_SUBSCRIPTION_ID`, `ACA_RESOURCE_GROUP`,
`ACA_SANDBOX_GROUP`, and `ACA_LOCATION`. Creating the group and role assignment
requires appropriate Azure permissions. Shared users need their own group-scoped
**Container Apps SandboxGroup Data Owner** assignment; an existing group does not
automatically grant another developer access.

For the upstream Microsoft .NET example instead:

```sh
./scripts/up.sh github.com/microsoft/vscode-remote-try-dotnet
```

The included [example](examples/dotnet/) is a minimal .NET 10 HTTP app with an
image-only `devcontainer.json`, based on the same Microsoft devcontainer image.

## Use an existing sandbox group

```sh
./scripts/install-provider.sh --subscription YOUR_DEV_SUBSCRIPTION_ID \
  -o ACA_RESOURCE_GROUP=rg-devsy-aca \
  -o ACA_SANDBOX_GROUP=devsy-sandboxes \
  -o ACA_LOCATION=eastus2

devsy workspace up ./examples/dotnet --id dotnet-aca --provider aca-sandboxes --devcontainer id:aca --ide vscode
ssh dotnet-aca.devsy 'dotnet --version'
ssh dotnet-aca.devsy 'bash smoke.sh'
```

The first workspace installs Docker in its Ubuntu sandbox, then Devsy injects its
agent and starts the devcontainer. The `aca` example profile mounts the sandbox's
egress CA bundle read-only and installs its roots in the devcontainer, so VS Code
downloads can use TLS verification. The example's default profile remains
portable to Docker outside ACA. Later connections reuse the container. Each new Devsy
machine gets its own sandbox. Do not change `ACA_DISK` to a non-Ubuntu image unless
you supply a compatible bootstrap.

## Agents window and self-hosted models

```sh
./scripts/open-agents.sh dotnet-aca
```

In the Agents window, add the SSH host `dotnet-aca.devsy`, then select the remote
repository folder. The generated SSH `ProxyCommand` routes through Devsy and ACA
WebSocket exec. See [Agent Host and BYOK setup](docs/agent-host.md) for VS Code
requirements, Copilot CLI configuration, and a self-hosted model endpoint template.
No model endpoint or model credentials are bundled.

## Lifecycle

```sh
devsy workspace stop dotnet-aca
devsy workspace up dotnet-aca --ide vscode
devsy workspace delete dotnet-aca
```

Stopping suspends the sandbox and preserves memory and disk. Deleting the
workspace deletes its sandbox; commit/export valuable work first. Group teardown
is a separate administrative operation:

```sh
aca sandboxgroup delete --name devsy-sandboxes --yes
```

See [architecture](docs/architecture.md), [security boundaries](docs/security.md),
and [validation](docs/validation.md) for the connection protocol, proof results,
and current limits. ACA Sandboxes and the Python SDK are preview surfaces.

## Development

```sh
python3 -m venv .venv
.venv/bin/python -m pip install -e . pytest
.venv/bin/python -m pytest
```

Primary references: [Devsy provider contract](https://devsy.sh/docs/developing-providers/quickstart),
[Microsoft Sandbox SDK](https://pypi.org/project/azure-containerapps-sandbox/), and
[VS Code Agents window](https://code.visualstudio.com/docs/agents/run/agents-window).
