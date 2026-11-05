#!/usr/bin/env bash
set -euo pipefail

# Install from a durable checkout: Devsy stores the absolute interpreter path.
provider_checkout=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
provider_name=${ACA_PROVIDER_NAME:-aca-sandboxes}
provider_python=${PYTHON:-python3}
provider_devsy=${DEVSY_BIN:-devsy}
provider_skip_init=false
provider_subscription=${ACA_SUBSCRIPTION_ID:-}
provider_options=(-o "ACA_PROVIDER_PYTHON=$provider_checkout/.venv/bin/python")
# Keep the infrastructure launcher and registered provider pointed at the same
# group. Explicit command-line -o values are appended later and take precedence.
for provider_option in ACA_RESOURCE_GROUP ACA_SANDBOX_GROUP ACA_LOCATION ACA_DISK ACA_CPU ACA_MEMORY ACA_AUTO_SUSPEND_SECONDS; do
  provider_value=${!provider_option-}
  if [[ -n $provider_value ]]; then
    provider_options+=(-o "$provider_option=$provider_value")
  fi
done

usage() {
  cat <<'USAGE'
Usage: scripts/install-provider.sh [--name NAME] [--subscription ID] [--skip-init] [-o KEY=VALUE ...]

Creates .venv, installs the Python provider, and registers it in Devsy without
changing the default provider. The subscription defaults to `az account show`.
ACA_* environment variables set the defaults. Use -o for provider options such
as ACA_RESOURCE_GROUP, ACA_SANDBOX_GROUP, ACA_LOCATION, or ACA_AZ_CLI.
Use DEVSY_BIN to select a Devsy CLI executable.
--skip-init registers the provider without checking Azure readiness.
USAGE
}

while (($#)); do
  case "$1" in
    --name|--subscription|-o|--option)
      if (($# < 2)); then printf 'Missing value for %s\n' "$1" >&2; exit 2; fi
      case "$1" in
        --name) provider_name=$2 ;;
        --subscription) provider_subscription=$2 ;;
        *) provider_options+=(-o "$2") ;;
      esac
      shift 2
      ;;
    --skip-init) provider_skip_init=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'Unknown argument: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
done

if ! command -v "$provider_devsy" >/dev/null 2>&1; then
  printf 'Devsy CLI not found. Install it from https://devsy.sh/docs/getting-started/install or set DEVSY_BIN.\n' >&2
  exit 1
fi
provider_az=${ACA_AZ_CLI:-$(command -v az || true)}
if [[ "$provider_az" != /* || ! -x "$provider_az" || "${provider_az##*/}" != az ]]; then
  printf 'Install Azure CLI or set ACA_AZ_CLI to the absolute path of az.\n' >&2
  exit 1
fi
provider_options=(-o "ACA_AZ_CLI=$provider_az" "${provider_options[@]}")
if [[ -z ${provider_subscription:-} ]]; then
  provider_subscription=$("$provider_az" account show --query id --output tsv)
fi
if [[ -z $provider_subscription ]]; then
  printf 'Specify --subscription ID or sign in with az login.\n' >&2
  exit 1
fi

"$provider_python" -m venv "$provider_checkout/.venv"
"$provider_checkout/.venv/bin/python" -m pip install --quiet --disable-pip-version-check "$provider_checkout"
# SSH clients invoke the provider from outside this checkout. An isolated
# import verifies the installed wheel independently of cwd and PYTHONPATH.
"$provider_checkout/.venv/bin/python" -I -c 'from importlib.resources import files; assert files("devsy_aca").joinpath("bootstrap.sh").is_file()'

provider_inventory=$("$provider_devsy" provider list --result-format json)
if printf '%s' "$provider_inventory" | \
    "$provider_checkout/.venv/bin/python" -c 'import json,sys; sys.exit(0 if sys.argv[1] in json.load(sys.stdin) else 1)' "$provider_name"; then
  "$provider_devsy" provider set-source "$provider_name" "$provider_checkout/provider.yaml" --use=false
else
  "$provider_devsy" provider add "$provider_checkout/provider.yaml" --name "$provider_name" --use=false
fi

# With --use=false Devsy only installs the manifest. Options are persisted by
# provider init, which does not change the user's selected default provider.
if [[ $provider_skip_init == true ]]; then
  "$provider_devsy" provider set "$provider_name" --skip-init \
    "${provider_options[@]}" -o "ACA_SUBSCRIPTION_ID=$provider_subscription"
else
  "$provider_devsy" provider init "$provider_name" \
    "${provider_options[@]}" -o "ACA_SUBSCRIPTION_ID=$provider_subscription"
fi
printf '\nProvider installed. Start the .NET sample with:\n  %q workspace up %q --id dotnet-aca --provider %q --devcontainer id:aca --ide vscode\n' \
  "$provider_devsy" "$provider_checkout/examples/dotnet" "$provider_name"
