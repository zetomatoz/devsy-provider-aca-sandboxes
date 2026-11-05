# Connection and isolation boundaries

The intended connection path is:

```text
VS Code / OpenSSH / Devsy on the developer's computer
  -> provider command on stdin/stdout
  -> authenticated Azure Sandbox HTTPS / WebSocket API
  -> command inside the sandbox
  -> Devsy workspace / development container
```

The provider does not need public sandbox ingress or a public SSH listener.
An SSH `ProxyCommand` carries protocol bytes over the provider's command stream;
SSH is an application protocol inside the authenticated transport. It does not
require a network connection to Azure on TCP port 22. A working corporate HTTPS
proxy must also permit the Azure service's streaming/WebSocket traffic.

The provider validates Azure's TLS certificate with the client system trust
store. Devsy's generated aliases separately use `StrictHostKeyChecking no` and
`UserKnownHostsFile /dev/null`. This setup authenticates the Azure exec API; it
does not independently pin the inner SSH host key. If your organization
requires host-key pinning, review that Devsy behavior before adopting the setup.

This is an architectural boundary, not a statement that every deployment or
client path has been tested. For a live run, verify all of these separately:

- No sandbox ports were exposed through the Sandbox port APIs.
- The effective SSH configuration contains a `ProxyCommand` and does not rely on
  a directly reachable sandbox address.
- Remote command execution succeeds over that stream, including binary data.
- VS Code's own Agents window can use that SSH entry on the installed version.

Azure credentials authorize access to the Sandbox API. Use interactive Azure
sign-in or a properly scoped workload identity. For shared deployments, assign
the documented **Container Apps SandboxGroup Data Owner** role at the smallest
appropriate scope. Subscription ownership is not a reason to copy an Azure token
or client secret into the container. See [Azure Sandbox access requirements](https://learn.microsoft.com/en-us/azure/container-apps/sandboxes-overview).

The remote code and agent execute inside the sandbox's isolation boundary. A
privileged container or Docker daemon inside that sandbox has broad authority
within the sandbox. Do not mount a developer machine's Docker socket, filesystem,
or cloud credential directories into it. Review any credential forwarding that
Devsy or a selected harness enables separately.

This provider sets `injectGitCredentials: false` and
`injectDockerCredentials: false` for workspace setup. Azure authentication
remains on the client that calls the Sandbox API. Devsy's SSH connection can
start separate services based on context settings, so the manifest's settings
alone do not disable credential forwarding on reconnect. The public sample
needs none of these services.

To disable SSH credential forwarding before creating or reconnecting workspaces
in your current Devsy context:

```sh
devsy context set \
  -o SSH_AGENT_FORWARDING=false \
  -o SSH_INJECT_GIT_CREDENTIALS=false \
  -o SSH_INJECT_DOCKER_CREDENTIALS=false \
  -o SSH_INJECT_GITHUB_CREDENTIALS=false \
  -o GIT_SSH_SIGNATURE_FORWARDING=false \
  -o GPG_AGENT_FORWARDING=false
```

This changes that Devsy context's preferences. For an individual
`devsy workspace ssh` call, `--agent-forwarding=false` also disables forwarding.
Check `ssh -G YOUR_WORKSPACE.devsy` for the resulting `forwardagent` value.
An agent socket normally does not reveal private key bytes, but remote processes
can ask it to authenticate while forwarding is active. Model and agent-harness
sign-ins are separate choices. Give private dependencies a dedicated, scoped
credential when needed.

Treat workspace code, downloaded features, lifecycle scripts, package feeds,
model tools, and agent instructions as executable inputs. Network isolation and
agent approval settings solve different problems. Restrict outbound access and
agent permissions according to the corporate environment rather than assuming
that having no inbound SSH port controls either of them.

Keep Agent Host connection tokens and model API keys private. Bind a manually
started host to localhost. If using VS Code dev tunnels, retain authentication;
an optional dev tunnel introduces another service and policy boundary.

Sandboxes are a preview service. Review lifetime, persistence, snapshot behavior,
costs, and corporate policy before relying on it for durable work. Commit or
export important changes before deleting a workspace or its sandbox group.
