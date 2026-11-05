# Validation record

Tested on November 4, 2026, against the `DEV` Azure subscription, resource group
`rg-devsy-aca`, SandboxGroup `devsy-sandboxes`, region `eastus2`. ACA CLI
`1.0.0-preview.5`, Python SDK `0.1.0b4`, Devsy `1.26.0`, and VS Code `1.139.1`.

| Check | Observed result |
| --- | --- |
| Azure provisioning | SandboxGroup provisioned; `aca doctor` passed 9/9; the signed-in principal has data access scoped to the SandboxGroup. |
| Docker in sandbox | Ubuntu sandbox ran Docker on a Unix socket and pulled and ran `hello-world`. |
| ACA transport | Live 1 MiB binary input matched SHA-256 after the stream; exact byte round trips, separate stderr, EOF, and nonzero exit status also passed. |
| Devsy | `workspace up` provisioned the sandbox, uploaded source, injected the Devsy agent, started the .NET devcontainer, and created the SSH alias. |
| Ingress | The sandbox port list was empty. Effective OpenSSH config used Devsy `workspace ssh --stdio` via `ProxyCommand`. |
| Remote build | .NET 10 built without warnings; both `/health` and `/` returned expected responses in the container. |
| Remote editor | VS Code showed the sample files under `SSH: dotnet-aca.devsy`. |
| Agents window | Connected via the same alias and relayed WebSocket traffic to a dedicated Agent Host running inside the devcontainer. The remote folder `/workspaces/dotnet-aca` was selectable. |
| Remote agent task | Copilot completed a session in the Agents window. With one-time approval it ran `pwd && dotnet --version && bash ./smoke.sh` in `/workspaces/dotnet-aca`: SDK `10.0.403`, zero build warnings or errors, and both HTTP assertions passed. |
| Fresh ACA profile | An independent workspace installed both sandbox CA roots from the read-only mount, fetched the VS Code update endpoint over verified HTTPS, and passed the .NET smoke test. |
| Lifecycle | Devsy stopped and resumed that workspace in the same sandbox and container; a marker file persisted. Devsy delete removed the disposable sandbox. |
| Unit tests | Eight tests passed for lifecycle mapping, creation and cleanup, byte transport, stderr, EOF, and exit status. |

The `dotnet-aca` workspace and its sandbox group were left available. The two
disposable verification sandboxes were removed. Self-hosted model configuration
is documented separately; no BYOK inference was run.

## First connection troubleshooting

The first editor connection failed with `No module named devsy_aca` in the
Remote - SSH log. An editable Python install resolved from the checkout but
failed from the GUI client's working directory. The installer now builds a
regular package, verifies a Python isolated import, and registers an isolated
module invocation. Rerun `./scripts/install-provider.sh` to refresh that install.
The installer also captures the absolute Azure CLI path, so GUI clients with a
minimal `PATH` can refresh the local Entra token. The connection passed from
outside the checkout with `/usr/bin:/bin:/usr/sbin:/sbin` as its only initial path.

ACA's egress inspection CA was trusted in the Ubuntu sandbox but not inherited
by the nested Docker image. An editor retry used verified HTTPS after adding the
sandbox-provided roots. The included `aca` devcontainer profile installs these
roots for future builds; it mounts only the CA bundle, read-only. Other images
using full egress inspection may need their own trust-store configuration.
The Agent Host CLI's first HTTP/2 download encountered a transient error; an
Agents window retry downloaded the matching CLI and connected successfully.

For a transport check from a terminal, use the generated alias and a bounded
command. Allow the first connection time to prepare the nested Devsy tunnel:

```sh
ssh -o BatchMode=yes -o ConnectTimeout=45 -o ForwardAgent=no \
  dotnet-aca.devsy 'pwd; dotnet --version; bash ./smoke.sh'
```
