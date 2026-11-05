#!/usr/bin/env bash
set -euo pipefail

# Run once per developer/team. Workspace lifecycle never creates role assignments.
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
if [[ -z "$sandbox_location" ]]; then
  # aca grants the signed-in principal the sandbox Data Owner role on this group.
  aca sandboxgroup create --subscription "$subscription" \
    --resource-group "$resource_group" --name "$sandbox_group" \
    --location "$location" --set-config
elif [[ "$sandbox_location" != "$location" ]]; then
  printf 'Sandbox group %s is in %s; set ACA_LOCATION to match.\n' "$sandbox_group" "$sandbox_location" >&2
  exit 1
fi

aca doctor --subscription "$subscription" --resource-group "$resource_group" \
  --sandbox-group "$sandbox_group" --region "$location"
printf '\nUse these provider options:\n'
printf '  ACA_SUBSCRIPTION_ID=%s\n  ACA_RESOURCE_GROUP=%s\n  ACA_SANDBOX_GROUP=%s\n  ACA_LOCATION=%s\n' \
  "$subscription" "$resource_group" "$sandbox_group" "$location"
