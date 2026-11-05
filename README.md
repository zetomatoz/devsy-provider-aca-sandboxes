# Devsy on Azure Container Apps Sandboxes

A Python Devsy provider that provisions a Linux ACA sandbox, runs a Docker dev
container inside it, and connects through the authenticated Sandbox API over
HTTPS/WebSocket. No inbound SSH port or public sandbox app port is required.

[![Start the .NET workspace](https://img.shields.io/badge/Devsy-Start%20.NET%20workspace-512BD4?logo=dotnet&logoColor=white)](#start-the-workspace)

The button opens the setup instructions.

Verified in Azure DEV: a .NET 10 workspace, the VS Code editor, and the Agents
window's remote Agent Host all ran through the Devsy proxy with no sandbox ports
exposed. Copilot built the app and passed both HTTP checks from the remote
workspace. See the [validation record](docs/validation.md).

## Start the workspace

With an active Azure subscription, clone this repo or [download the ZIP](https://github.com/zetomatoz/devsy-provider-aca-sandboxes/archive/refs/heads/main.zip)
and extract it. Open a terminal in the project folder and run:

```sh
bash scripts/quickstart.sh
```

The quickstart installs missing tools, including Python, Azure CLI, Devsy, the
ACA Sandbox CLI, and VS Code with Remote SSH. It prompts for Azure sign-in if
needed, provisions the Azure resources, and opens the .NET workspace in VS Code.
Docker and .NET run inside the sandbox.

Automatic tool installation supports Apple Silicon macOS and x86-64 Ubuntu
22.04, 24.04, and 26.04 or Debian 12. Package installation may ask for local
administrator access. Keep the checkout in a durable folder because Devsy uses
its Python virtual environment by absolute path.

On **Windows x64**, open PowerShell in the project folder and run:

```powershell
.\scripts\quickstart.ps1 -Subscription 'YOUR_SUBSCRIPTION_ID'
```

This runs the headless quickstart in Ubuntu on WSL2. See [Windows setup](docs/windows.md)
for installing WSL, optional Copilot CLI, and running the smoke test.

Use a Microsoft Entra user with permission to create Azure resources and assign
roles, such as a subscription Owner. `--subscription ID_OR_NAME` selects a
specific subscription on macOS and Linux. On a terminal-only machine use
`bash scripts/quickstart.sh --headless --device-code`.

The script creates `rg-devsy-aca` in `eastus2` and deploys [the Bicep template](infra/main.bicep)
to create `devsy-sandboxes` and grant the signed-in user **Container Apps
SandboxGroup Data Owner** on that sandbox group. Devsy then creates `dotnet-aca`.
The sandbox suspends after five minutes of Azure-detected inactivity by default.
Running compute and retained storage follow [Azure's pricing](https://sandboxes.azure.com/docs/sandboxes/cost).

Override infrastructure defaults with `ACA_SUBSCRIPTION_ID`, `ACA_RESOURCE_GROUP`,
`ACA_SANDBOX_GROUP`, and `ACA_LOCATION`. For multiple simultaneous setups, use a
distinct `ACA_PROVIDER_NAME` and `ACA_WORKSPACE_NAME` for each target.

The launcher prints the smoke test command. If Devsy was just installed, add
`$HOME/.local/bin` to your shell's `PATH` first:

```sh
export PATH="$HOME/.local/bin:$PATH"
devsy workspace ssh --start-services=false --agent-forwarding=false --command 'bash ./smoke.sh' dotnet-aca
```

Use `--with-copilot` to install the optional standalone Copilot CLI on your
computer. Hosted Copilot requires a separate GitHub account with Copilot access.
The .NET sample and smoke test use your Azure sign-in. See [Copilot authentication](https://docs.github.com/en/copilot/how-tos/copilot-cli/set-up-copilot-cli/authenticate-copilot-cli).

To install just the workstation tools, use `scripts/install-tools.sh`. Use
`scripts/bootstrap-azure.sh` for Azure provisioning after signing in, or
`scripts/up.sh` to launch with your existing toolchain.

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

Azure automatically suspends a sandbox after **five minutes of inactivity** by
default. Change the timeout in seconds (minimum 60) when launching or registering
the provider:

```sh
ACA_AUTO_SUSPEND_SECONDS=120 ./scripts/install-provider.sh
```

Use `300` to update an older installation that saved the previous 30-minute
default. The provider checks the policy on creation and on the next
workspace start or connection, and applies the configured timeout if it differs.

Azure counts open shells, API execution, incoming traffic, and file operations
as activity. Disconnect the remote editor and Agents window when you finish so
the sandbox can become idle. A stopped sandbox incurs no CPU or memory charges.
Retained snapshots follow [Azure's storage pricing](https://sandboxes.azure.com/docs/sandboxes/cost).
See [what Azure counts as idle](https://learn.microsoft.com/en-us/azure/container-apps/sandboxes-overview#lifecycle-states).

To stop immediately, resume, or delete a workspace:

```sh
devsy workspace stop dotnet-aca
devsy workspace up dotnet-aca --ide vscode
devsy workspace delete dotnet-aca
```

Stopping suspends the sandbox and preserves memory and disk. Deleting the
workspace deletes its sandbox; commit/export valuable work first. Group teardown
is a separate administrative operation:

```sh
aca sandboxgroup delete --subscription YOUR_DEV_SUBSCRIPTION_ID \
  --resource-group rg-devsy-aca --name devsy-sandboxes --yes
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

See [testing the quickstart](docs/testing.md) for the credential-free CI checks,
Azure's Bicep validation, and a disposable live test you can point at a test
subscription.

Primary references: [Devsy provider contract](https://devsy.sh/docs/developing-providers/quickstart),
[Microsoft Sandbox SDK](https://pypi.org/project/azure-containerapps-sandbox/), and
[VS Code Agents window](https://code.visualstudio.com/docs/agents/run/agents-window).
