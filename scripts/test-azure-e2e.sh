#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: scripts/test-azure-e2e.sh --subscription ID_OR_NAME [--location REGION]

Deploy a disposable ACA sandbox group, start the .NET workspace with Devsy,
and check the application from inside the dev container. The default region
is eastus2. The test uses billable Azure resources and deletes its resource
group on exit. Use a test subscription where you can assign roles.

Requires Git, Python 3.10+, Devsy, the ACA CLI, Azure CLI with Bicep, and an
Azure CLI login as a Microsoft Entra user. No editor or agent login is needed.
USAGE
}

subscription_input=''
location=eastus2
while (($#)); do
  case "$1" in
    --subscription|--location)
      if (($# < 2)) || [[ -z "$2" || "$2" == -* ]]; then
        printf 'Missing value for %s\n' "$1" >&2
        exit 2
      fi
      case "$1" in
        --subscription) subscription_input=$2 ;;
        --location) location=$2 ;;
      esac
      shift 2
      ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'Unknown argument: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
done

if [[ -z "$subscription_input" || ! "$location" =~ ^[a-z0-9]+$ ]]; then
  usage >&2
  exit 2
fi

checkout=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
devsy_bin=${DEVSY_BIN:-devsy}
python_bin=${PYTHON:-python3}
for tool in az aca git "$devsy_bin" "$python_bin"; do
  command -v "$tool" >/dev/null || { printf 'Install %s first.\n' "$tool" >&2; exit 1; }
done
if ! az bicep version >/dev/null 2>&1; then
  printf 'Install Bicep first with az bicep install.\n' >&2
  exit 1
fi
if ! "$python_bin" -c 'import sys; sys.exit(sys.version_info < (3, 10))'; then
  printf 'Python 3.10 or newer is required.\n' >&2
  exit 1
fi

subscription=$(az account show --subscription "$subscription_input" --query id --output tsv)
if [[ ! "$subscription" =~ ^[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$ ]]; then
  printf 'Could not resolve the Azure subscription to an ID.\n' >&2
  exit 1
fi
az account get-access-token --subscription "$subscription" \
  --resource https://management.azure.com --output none

run_id=$("$python_bin" -c 'import uuid; print(uuid.uuid4().hex)')
resource_group="rg-devsy-aca-e2e-$run_id"
azure_scope=(--subscription "$subscription" --name "$resource_group")
if [[ "$(az group exists "${azure_scope[@]}" --output tsv)" != false ]]; then
  printf 'Could not confirm resource group %s is available.\n' "$resource_group" >&2
  exit 1
fi

run_dir=$(mktemp -d "${TMPDIR:-/tmp}/devsy-aca-e2e.XXXXXXXX")
test_checkout="$run_dir/checkout"
group_attempted=false
workspace_attempted=false

cleanup() {
  local result=$?
  local group_exists group_owner
  trap - EXIT INT TERM

  if [[ "$group_attempted" == true ]]; then
    group_exists=$(az group exists "${azure_scope[@]}" --output tsv) || group_exists=unknown
    if [[ "$group_exists" != false ]]; then
      group_owner=$(az group show "${azure_scope[@]}" --query 'tags."devsy-e2e-run"' --output tsv) || group_owner=unknown
      if [[ "$group_owner" == "$run_id" ]]; then
        if [[ "$workspace_attempted" == true ]]; then
          "$devsy_bin" workspace delete "$ACA_WORKSPACE_NAME" --force --ignore-not-found \
            --grace-period 90s || printf 'Devsy cleanup failed. Deleting the resource group.\n' >&2
        fi
        printf 'Deleting test resource group %s.\n' "$resource_group"
        if ! az group delete "${azure_scope[@]}" --yes --output none ||
          [[ "$(az group exists "${azure_scope[@]}" --output tsv)" != false ]]; then
          printf 'Could not verify deletion. To retry cleanup, run\n  az group delete --subscription %q --name %q --yes\n' \
            "$subscription" "$resource_group" >&2
          if ((result == 0)); then result=1; fi
        fi
      else
        printf 'Could not verify ownership of %s in subscription %s. Check its devsy-e2e-run tag for %s before deleting it.\n' \
          "$resource_group" "$subscription" "$run_id" >&2
        if ((result == 0)); then result=1; fi
      fi
    fi
  fi

  if ! rm -r -- "$run_dir"; then
    printf 'Could not remove temporary files in %s.\n' "$run_dir" >&2
    if ((result == 0)); then result=1; fi
  fi
  if ((result == 0)); then
    printf 'PASS: ACA deployment, Devsy .NET smoke test, and resource cleanup.\n'
  fi
  exit "$result"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# Use tracked working-tree files so a build or local settings cannot leak into
# the sample, and package the provider in a separate virtual environment.
mkdir "$test_checkout"
git -C "$checkout" ls-files -z -- README.md provider.yaml pyproject.toml devsy_aca \
  infra examples/dotnet scripts/bootstrap-azure.sh scripts/install-provider.sh scripts/up.sh |
  tar -C "$checkout" --null -T - -cf - | tar -C "$test_checkout" -xf -

unset DEVSY_CONTEXT DEVSY_PROVIDER ACA_AZ_CLI ACA_DISK ACA_CPU ACA_MEMORY ACA_AUTO_SUSPEND_SECONDS
export DEVSY_HOME="$run_dir/devsy"
export ACA_SUBSCRIPTION_ID="$subscription" ACA_RESOURCE_GROUP="$resource_group"
export ACA_LOCATION="$location" ACA_SANDBOX_GROUP=devsy-sandboxes ACA_PROVIDER_NAME=aca-sandboxes
export ACA_WORKSPACE_NAME=dotnet-aca-e2e ACA_IDE=none
"$devsy_bin" context set -o "SSH_CONFIG_PATH=$run_dir/ssh-config" \
  -o SSH_ADD_PRIVATE_KEYS=false -o SSH_AGENT_FORWARDING=false \
  -o GIT_SSH_SIGNATURE_FORWARDING=false -o SSH_INJECT_GIT_CREDENTIALS=false \
  -o SSH_INJECT_DOCKER_CREDENTIALS=false

printf 'Testing subscription %s in %s with resource group %s.\n' "$subscription" "$location" "$resource_group"
group_attempted=true
az group create "${azure_scope[@]}" --location "$location" \
  --tags project=devsy-aca purpose=integration-test "devsy-e2e-run=$run_id" --output none
workspace_attempted=true
bash "$test_checkout/scripts/up.sh" "$test_checkout/examples/dotnet" --ssh-configure=false
"$devsy_bin" workspace ssh "$ACA_WORKSPACE_NAME" --start-services=false --agent-forwarding=false \
  --command 'bash ./smoke.sh'
