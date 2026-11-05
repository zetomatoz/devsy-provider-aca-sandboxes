#!/usr/bin/env bash
set -euo pipefail

# Run once per developer/team. Workspace lifecycle never creates role assignments.
checkout=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
for tool in az aca; do
  command -v "$tool" >/dev/null || { echo "Install $tool first." >&2; exit 1; }
done

subscription="${ACA_SUBSCRIPTION_ID:-$(az account show --query id -o tsv)}"
resource_group="${ACA_RESOURCE_GROUP:-rg-devsy-aca}"
sandbox_group="${ACA_SANDBOX_GROUP:-devsy-sandboxes}"
location="${ACA_LOCATION:-eastus2}"

# account show can succeed with an expired cached token; request a real token.
az account get-access-token --subscription "$subscription" \
  --resource https://management.azure.com --output none
group_exists=$(az group exists --subscription "$subscription" --name "$resource_group")
if [[ "$group_exists" == false ]]; then
  az group create --subscription "$subscription" --name "$resource_group" \
    --location "$location" --tags project=devsy-aca purpose=proof-of-concept \
    --output none
fi

sandbox_location=$(az resource list --subscription "$subscription" --resource-group "$resource_group" \
  --resource-type Microsoft.App/sandboxGroups --name "$sandbox_group" \
  --query '[0].location' --output tsv)
if [[ -n "$sandbox_location" && "$sandbox_location" != "$location" ]]; then
  printf 'Sandbox group %s is in %s; set ACA_LOCATION to match.\n' "$sandbox_group" "$sandbox_location" >&2
  exit 1
fi

aca_scope=(--subscription "$subscription" --resource-group "$resource_group" \
  --group "$sandbox_group" --region "$location")
if [[ -z "$sandbox_location" ]] || ! aca sandbox list "${aca_scope[@]}" >/dev/null 2>&1; then
  principal_id=$(az rest --subscription "$subscription" --method get \
    --url 'https://graph.microsoft.com/v1.0/me?$select=id' --query id --output tsv)
  if [[ -z "$principal_id" ]]; then
    printf 'Sign in to Azure CLI with a Microsoft Entra user to deploy this quickstart.\n' >&2
    exit 1
  fi

  create_group=false
  existing_assignment=''
  if [[ -z "$sandbox_location" ]]; then
    create_group=true
    registration=$(az provider show --subscription "$subscription" --namespace Microsoft.App \
      --query registrationState --output tsv)
    if [[ "$registration" != Registered ]]; then
      az provider register --subscription "$subscription" --namespace Microsoft.App --wait
    fi
  else
    scope="/subscriptions/$subscription/resourceGroups/$resource_group/providers/Microsoft.App/sandboxGroups/$sandbox_group"
    existing_assignment=$(az role assignment list --subscription "$subscription" --scope "$scope" \
      --assignee-object-id "$principal_id" --include-inherited --fill-principal-name false \
      --query "[?ends_with(roleDefinitionId, '/c24cf47c-5077-412d-a19c-45202126392c')].id | [0]" --output tsv)
  fi

  if [[ -z "$existing_assignment" ]]; then
    if ! az bicep version >/dev/null 2>&1; then
      az bicep install
    fi
    printf 'Deploying the sandbox group and scoped data access in Azure.\n'
    az deployment group create --subscription "$subscription" --resource-group "$resource_group" \
      --name "devsy-aca-$sandbox_group" --template-file "$checkout/infra/main.bicep" \
      --parameters sandboxGroupName="$sandbox_group" location="$location" principalId="$principal_id" \
      createSandboxGroup="$create_group" --output none
  fi

  # ARM can finish before the data-plane role becomes usable.
  for attempt in {1..12}; do
    if aca sandbox list "${aca_scope[@]}" >/dev/null 2>&1; then
      break
    fi
    if [[ "$attempt" == 12 ]]; then
      printf 'Sandbox access is still unavailable. Check the role and rerun setup after Azure RBAC propagates.\n' >&2
      aca sandbox list "${aca_scope[@]}" >/dev/null
      break
    fi
    if [[ "$attempt" == 1 ]]; then
      printf 'Waiting for sandbox data access to propagate.\n'
    fi
    sleep 5
  done
fi

aca doctor --subscription "$subscription" --resource-group "$resource_group" \
  --sandbox-group "$sandbox_group" --region "$location"
printf '\nUse these provider options:\n'
printf '  ACA_SUBSCRIPTION_ID=%s\n  ACA_RESOURCE_GROUP=%s\n  ACA_SANDBOX_GROUP=%s\n  ACA_LOCATION=%s\n' \
  "$subscription" "$resource_group" "$sandbox_group" "$location"
