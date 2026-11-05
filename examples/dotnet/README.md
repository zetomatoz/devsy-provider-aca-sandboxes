# .NET workspace example

This minimal ASP.NET Core app uses .NET 10. Its image-only Dev Container
configuration follows the image used by Microsoft's
[.NET Dev Containers sample](https://github.com/microsoft/vscode-remote-try-dotnet).
It needs no Dockerfile, Docker Compose service, or external package dependency.

To try the existing public sample directly, point Devsy at
`github.com/microsoft/vscode-remote-try-dotnet` with this provider. To try this
example, run the provider's launch workflow with this directory as the workspace
source. Local directories are uploaded by Devsy; do not include credentials.

Inside the workspace, this smoke test builds the app, starts it on loopback,
asserts the HTTP response, and cleans up the process:

```sh
./smoke.sh
```

For an interactive run:

```sh
dotnet run --urls http://0.0.0.0:5080
```

For a browser preview, forward port 5080 from VS Code's Ports view. It can use
any free local port. This uses the Devsy connection and needs no Azure Sandbox
public port.

An initial agent task can be: "Run ./smoke.sh, add a /version endpoint returning
the application's assembly version, then validate both endpoints."
