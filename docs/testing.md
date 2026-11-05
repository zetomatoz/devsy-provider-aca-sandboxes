# Test the quickstart

Test the local toolchain, the Azure template, and the running workspace separately.
Each check covers failures the previous one cannot see.

| Check | What it proves | Azure resources created |
| --- | --- | --- |
| [GitHub Actions](../.github/workflows/validate.yml) | Tools install on clean Ubuntu, Python provider tests pass, Bash and Windows PowerShell parse, Bicep compiles | None |
| Azure ARM validation and what-if | Azure evaluates the template at a real scope and previews the resource and role changes | None |
| Disposable Azure smoke test | Bicep and role assignment work, Devsy reaches the .NET dev container through the authenticated proxy, and HTTP checks pass inside the container | One temporary resource group, sandbox group and sandbox |

## Preview the deployment

Use Azure CLI 2.76 or later, an existing test resource group, and a signed-in
Microsoft Entra user who has deployment and role assignment permissions there.
Use an unused sandbox group name to preview the create path.

```sh
subscription='YOUR_TEST_SUBSCRIPTION_ID'
group='YOUR_EXISTING_TEST_RESOURCE_GROUP'
principal=$(az rest --subscription "$subscription" --method get \
  --url 'https://graph.microsoft.com/v1.0/me?$select=id' --query id -o tsv)
az deployment group what-if --subscription "$subscription" --resource-group "$group" \
  --template-file infra/main.bicep --validation-level Provider \
  --parameters sandboxGroupName=devsy-sandboxes-preview location=eastus2 principalId="$principal"
```

Use `az deployment group validate` with the same arguments if you only want
validation. [Azure's Bicep what-if docs](https://learn.microsoft.com/en-us/azure/azure-resource-manager/bicep/deploy-what-if)
also describe `bicep snapshot` for offline template comparisons. These checks
cannot exercise data-plane access, the sandbox image, or the Devsy connection.

## Run a disposable Azure test

Use an explicitly chosen test subscription. A separate subscription checks
permissions, policies, provider registration, and quota independently of your
regular setup. [Microsoft recommends sandbox subscriptions](https://learn.microsoft.com/en-us/azure/cloud-adoption-framework/ready/considerations/sandbox-environments)
for this kind of isolated proof of concept. A separate resource group in an
existing subscription is still useful, but shares its registration, policy, and
quota. Use a region that supports ACA Sandboxes.

From a Git checkout on macOS, Linux, or Ubuntu on WSL2:

```sh
bash scripts/install-tools.sh
export PATH="$HOME/.local/bin:$PATH"
az login --use-device-code
az bicep install
bash scripts/test-azure-e2e.sh --subscription YOUR_TEST_SUBSCRIPTION_ID
```

The script uses a fresh Devsy home and checkout copy, creates a uniquely named
resource group, runs the normal Azure bootstrap and workspace setup, and executes
the [.NET HTTP smoke test](../examples/dotnet/smoke.sh) through Devsy. It uses real,
billable resources. On normal exit, error, or handled interrupt it attempts
cleanup and verifies that the test group is gone. If the process is killed or
Azure cleanup fails, use the printed resource group name to check for leftovers.
The Azure bootstrap may register `Microsoft.App` in the test subscription; that
registration is intentionally left in place.

This test covers the headless path. To verify the whole first-run experience,
start on a fresh supported workstation and follow the README against a separate
test subscription. On Windows, include WSL installation and the PowerShell
launcher. To verify the editor and agent paths, include opening VS Code, making a
remote connection, and running one task in the Agents window. [Azure DevTest Labs](https://learn.microsoft.com/en-us/azure/devtest-labs/devtest-lab-overview)
can provide disposable Windows VMs; for WSL2 use a VM configuration that supports
[nested virtualization](https://learn.microsoft.com/en-us/windows/wsl/faq#can-i-run-wsl-2-in-a-virtual-machine).
Those VMs are test clients for the real Azure service.
