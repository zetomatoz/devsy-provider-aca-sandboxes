#!/usr/bin/env bash
set -euo pipefail

checkout=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
subscription=${ACA_SUBSCRIPTION_ID:-}
headless=false
with_copilot=false
login_args=(--output none)

usage() {
  cat <<'USAGE'
Usage: ./scripts/quickstart.sh [--subscription ID_OR_NAME] [--headless]
                             [--with-copilot] [--device-code]

Install the workstation tools, sign in to Azure if needed, deploy the sandbox
group, and launch the .NET sample. The default editor is VS Code with Remote SSH.
Use --headless for a terminal workspace or --with-copilot to install Copilot CLI
on this computer. Use --device-code to sign in from a separate browser.
USAGE
}

while (($#)); do
  case "$1" in
    --subscription)
      if (($# < 2)) || [[ -z "$2" || "$2" == --* ]]; then
        printf 'Provide an Azure subscription name or ID.\n' >&2
        exit 2
      fi
      subscription=$2
      shift 2
      ;;
    --headless) headless=true; shift ;;
    --with-copilot) with_copilot=true; shift ;;
    --device-code) login_args+=(--use-device-code); shift ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'Unknown option: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
done

if [[ $(uname -s) == Darwin ]]; then
  export PATH="/opt/homebrew/bin:$PATH"
fi
export PATH="${DEVSY_EDITOR_TOOLS_PREFIX:-$HOME/.local}/bin:$HOME/.local/bin:$PATH"
bash "$checkout/scripts/install-tools.sh"
if [[ "$headless" == true ]]; then
  export ACA_IDE=none
else
  set -- --with-vscode
fi
if [[ "$with_copilot" == true ]]; then
  set -- "$@" --with-copilot
fi
if (($#)); then
  bash "$checkout/scripts/install-editor-tools.sh" "$@"
fi

account_args=(--only-show-errors)
if [[ -n "$subscription" ]]; then
  account_args+=(--subscription "$subscription")
fi
if ! az account get-access-token "${account_args[@]}" \
  --resource https://management.azure.com --output none 2>/dev/null; then
  az login "${login_args[@]}"
fi
ACA_SUBSCRIPTION_ID=$(az account show "${account_args[@]}" --query id --output tsv)
if [[ -z "$ACA_SUBSCRIPTION_ID" ]]; then
  printf 'Select an active Azure subscription before continuing.\n' >&2
  exit 1
fi
export ACA_SUBSCRIPTION_ID

bash "$checkout/scripts/up.sh"

workspace=${ACA_WORKSPACE_NAME:-dotnet-aca}
printf '\nRun the smoke test in the workspace:\n'
printf '  %q workspace ssh --start-services=false --agent-forwarding=false --command %q %q\n' \
  "${DEVSY_BIN:-devsy}" 'bash ./smoke.sh' "$workspace"
printf 'Stop the workspace when finished:\n  %q workspace stop %q\n' "${DEVSY_BIN:-devsy}" "$workspace"
