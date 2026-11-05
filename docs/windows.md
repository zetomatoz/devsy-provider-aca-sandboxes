# Start from Windows

The PowerShell launcher uses **Ubuntu on WSL2** on x64 Windows. It installs the
Linux command-line tools inside Ubuntu, signs into Azure, deploys the sandbox
group, and starts the same .NET workspace as the macOS and Linux quickstart.
The workspace runs in Azure; Windows does not need Docker Desktop or the .NET SDK.

1. Clone the repository or extract the [ZIP](https://github.com/zetomatoz/devsy-provider-aca-sandboxes/archive/refs/heads/main.zip)
   to a folder you will keep. Open PowerShell in that folder.
2. If Ubuntu on WSL2 is missing, run this in an administrator PowerShell:

   ```powershell
   .\scripts\quickstart.ps1 -InstallWsl
   ```

   Restart if prompted and launch Ubuntu once to create a Linux user. See
   [Microsoft's WSL installation guide](https://learn.microsoft.com/en-us/windows/wsl/install)
   for prerequisites and troubleshooting.
3. Run the launcher from your regular PowerShell session:

   ```powershell
   .\scripts\quickstart.ps1 -Subscription 'YOUR_SUBSCRIPTION_ID'
   ```

   Use `-Distribution Ubuntu-24.04` if that is the name shown by `wsl --list --verbose`.
   The launcher uses Azure device code sign-in if needed. Add `-BrowserLogin` if
   your organization blocks device code sign-in and your WSL browser integration
   is configured. Add `-WithCopilot` to install the optional Copilot CLI inside
   Ubuntu. Copilot has its own GitHub sign-in and access requirements.

To test and then suspend the workspace, open an Ubuntu shell (`wsl -d Ubuntu`,
or substitute the distribution you used) and run:

```sh
export PATH="$HOME/.local/bin:$PATH"
devsy workspace ssh --start-services=false --agent-forwarding=false --command 'bash ./smoke.sh' dotnet-aca
devsy workspace stop dotnet-aca
```

The Windows launcher is headless. It does not set up Windows VS Code Remote SSH
or the Agents window. The workspace and proxy configuration live in Ubuntu.

If PowerShell blocks the downloaded script, review it first. If your execution
policy permits local scripts, unblock that file with
`Unblock-File -LiteralPath .\scripts\quickstart.ps1` and try again.

If the checkout on `C:` gives file permission or virtual environment errors,
clone a fresh copy inside Ubuntu and run
`bash scripts/quickstart.sh --headless --device-code --subscription YOUR_SUBSCRIPTION_ID`
there. Keep separate checkouts if you also run the installer on another OS.
Microsoft [recommends the WSL filesystem](https://learn.microsoft.com/en-us/windows/wsl/filesystems)
for Linux tools.
