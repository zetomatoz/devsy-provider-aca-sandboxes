#!/usr/bin/env bash
set -euo pipefail

provider_checkout=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
provider_devsy=${DEVSY_BIN:-devsy}
provider_name=${ACA_PROVIDER_NAME:-aca-sandboxes}
workspace_name=${ACA_WORKSPACE_NAME:-dotnet-aca}
workspace_source=${1:-"$provider_checkout/examples/dotnet"}
if (($#)); then shift; fi
if [[ "$workspace_source" == "$provider_checkout/examples/dotnet" ]]; then
  set -- --devcontainer id:aca "$@"
fi

"$provider_checkout/scripts/bootstrap-azure.sh"
"$provider_checkout/scripts/install-provider.sh" \
  --subscription "${ACA_SUBSCRIPTION_ID:-$(az account show --query id -o tsv)}" \
  -o "ACA_RESOURCE_GROUP=${ACA_RESOURCE_GROUP:-rg-devsy-aca}" \
  -o "ACA_SANDBOX_GROUP=${ACA_SANDBOX_GROUP:-devsy-sandboxes}" \
  -o "ACA_LOCATION=${ACA_LOCATION:-eastus2}"
exec "$provider_devsy" workspace up "$workspace_source" \
  --id "$workspace_name" --provider "$provider_name" --ide vscode "$@"
