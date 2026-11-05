# Provider design

Devsy's provider commands are ordinary executables. This provider is written in
Python and implements the machine lifecycle contract. One Devsy machine maps to
one ACA sandbox. Devsy's Docker driver builds and runs the repository's
`devcontainer.json` inside that sandbox.

The intended connection path is:

```text
VS Code / Agents window
  -> SSH profile: <workspace>.devsy
  -> ProxyCommand: devsy workspace ssh --stdio
  -> provider exec.command (Python)
  -> authenticated ACA exec WebSocket over TLS / port 443
  -> Devsy agent in the sandbox
  -> dev container / agent host
```

SSH is a protocol inside the stream. It does not require a network SSH listener,
an Azure public IP, or a port-22 ingress rule. The sandbox is the hardware
isolation boundary; the dev container is a developer tooling boundary inside it.

ACA Sandboxes are `Microsoft.App/sandboxGroups`. They are different from regular
Container Apps and from Dynamic Sessions (`sessionPools`). The Python SDK handles
lifecycle and Docker bootstrap. The transport uses the preview `exec/stream`
WebSocket endpoint with the same Entra audience as the SDK. The bearer token
stays on the client and is sent in the TLS upgrade request.

In live tests the service returned EOF immediately on piped stdin with non-PTY
exec, even with stdin requested. The provider starts a raw PTY and waits for a
readiness marker, then multiplexes base64 frames. A small Python process in the
sandbox gives the Devsy command ordinary pipes. It forwards stdout, stderr, EOF,
and exit status separately. There is no PTY exposed to the Devsy process itself.
The preview framing is an integration dependency; rerun the live smoke test when
upgrading ACA or Devsy.

Provider commands must leave stdout free of logs during `command` and print only
Devsy's expected state (`Running`, `Stopped`, `Busy`, or `NotFound`) during `status`.
Operational diagnostics belong on stderr.

## References

- [Devsy provider development](https://devsy.sh/docs/developing-providers/quickstart)
- [Devsy provider options](https://devsy.sh/docs/developing-providers/options)
- [ACA Sandboxes overview](https://learn.microsoft.com/en-us/azure/container-apps/sandboxes-overview)
- [Microsoft's Python SDK](https://pypi.org/project/azure-containerapps-sandbox/)

See the README and validation record for what has actually been demonstrated.
