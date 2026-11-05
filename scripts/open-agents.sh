#!/usr/bin/env bash
set -euo pipefail

if [[ $# -gt 1 ]]; then
  printf 'Usage: %s [workspace-name]\n' "$0" >&2
  exit 2
fi

agents_workspace=${1:-}
if [[ -n "$agents_workspace" && ! "$agents_workspace" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]*$ ]]; then
  printf 'Workspace name must contain only letters, numbers, dots, underscores, or hyphens.\n' >&2
  exit 2
fi

agents_cli=${VSCODE_CLI:-}
if [[ -z "$agents_cli" ]]; then
  if command -v code >/dev/null 2>&1; then
    agents_cli=$(command -v code)
  elif [[ -x '/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code' ]]; then
    agents_cli='/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code'
  else
    printf 'VS Code CLI not found. Install it on PATH or set VSCODE_CLI to its executable path.\n' >&2
    exit 1
  fi
fi

if [[ ! -x "$agents_cli" ]]; then
  printf 'VS Code CLI is not executable: %s\n' "$agents_cli" >&2
  exit 1
fi

if [[ -n "$agents_workspace" ]]; then
  agents_alias=$agents_workspace
  [[ "$agents_alias" == *.devsy ]] || agents_alias="${agents_alias}.devsy"
  printf 'In the Agents window, choose Workspace -> Remote -> SSH -> %s.\n' "$agents_alias"
  printf 'Select the repository folder inside that workspace and choose a harness.\n'
fi
exec "$agents_cli" --agents
