#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/install-editor-tools.sh [--with-vscode] [--with-copilot]

  --with-vscode   Install VS Code Desktop if needed and add Remote SSH.
  --with-copilot  Install the optional standalone GitHub Copilot CLI.

Supports macOS and Linux. New command links and the Copilot CLI go to
~/.local/bin by default. Set DEVSY_EDITOR_TOOLS_PREFIX to choose another
user-owned install prefix. VSCODE_CLI can point to an existing desktop CLI.

Hosted Copilot uses a GitHub account with Copilot access. Azure sign-in covers
the sandbox. Copilot CLI can also use a configured BYOK model provider.
EOF
}

with_vscode=false
with_copilot=false
while (( $# )); do
  case $1 in
    --with-vscode) with_vscode=true ;;
    --with-copilot) with_copilot=true ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'Unknown option %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done
if ! $with_vscode && ! $with_copilot; then
  usage
  exit 0
fi

editor_os=$(uname -s)
case $editor_os in
  Darwin|Linux) ;;
  *) printf 'Editor tool installation supports macOS and Linux.\n' >&2; exit 1 ;;
esac

editor_prefix=${DEVSY_EDITOR_TOOLS_PREFIX:-"$HOME/.local"}
if [[ $editor_prefix != /* ]]; then
  printf 'DEVSY_EDITOR_TOOLS_PREFIX must be an absolute path.\n' >&2
  exit 2
fi
editor_bin_dir=$editor_prefix/bin
editor_tmp=
editor_install_lock=
cleanup() {
  if [[ -n $editor_tmp ]]; then rm -rf -- "$editor_tmp"; fi
  if [[ -n $editor_install_lock ]]; then rmdir -- "$editor_install_lock"; fi
}
trap cleanup EXIT

fetch_https() {
  curl --disable --fail --silent --show-error --location \
    --proto '=https' --proto-redir '=https' --connect-timeout 15 --max-time 900 "$@"
}

find_vscode() {
  if [[ -n ${VSCODE_CLI:-} ]]; then
    if [[ ! -x $VSCODE_CLI ]]; then
      printf 'VSCODE_CLI is not executable: %s\n' "$VSCODE_CLI" >&2
      return 1
    fi
    printf '%s\n' "$VSCODE_CLI"
  elif command -v code >/dev/null 2>&1; then
    command -v code
  elif [[ -x $editor_bin_dir/code ]]; then
    printf '%s\n' "$editor_bin_dir/code"
  elif [[ $editor_os == Darwin && -x '/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code' ]]; then
    printf '%s\n' '/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code'
  elif [[ $editor_os == Darwin && -x $HOME/Applications/Visual\ Studio\ Code.app/Contents/Resources/app/bin/code ]]; then
    printf '%s\n' "$HOME/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code"
  fi
}

install_vscode() {
  local artifact target cli_relative cli_path metadata archive_url archive_hash archive extracted lock
  if [[ $editor_os == Darwin ]]; then
    artifact=darwin-universal
    target="$HOME/Applications/Visual Studio Code.app"
    cli_relative=Contents/Resources/app/bin/code
  else
    case $(uname -m) in
      x86_64|amd64) artifact=linux-x64 ;;
      aarch64|arm64) artifact=linux-arm64 ;;
      armv7l) artifact=linux-armhf ;;
      *) printf 'No VS Code archive for architecture %s.\n' "$(uname -m)" >&2; return 1 ;;
    esac
    target=$editor_prefix/opt/devsy-vscode
    cli_relative=bin/code
  fi
  cli_path=$target/$cli_relative

  mkdir -p -- "$(dirname -- "$target")" "$editor_bin_dir"
  lock=$target.devsy-install-lock
  if ! mkdir -- "$lock"; then
    printf 'Cannot acquire VS Code install lock %s\n' "$lock" >&2
    return 1
  fi
  editor_install_lock=$lock
  if [[ ! -x $cli_path ]]; then
    if [[ -e $target || -L $target ]]; then
      printf 'Existing path %s has no VS Code CLI. Set VSCODE_CLI or move that path before retrying.\n' "$target" >&2
      return 1
    fi
    editor_tmp=$(mktemp -d "$(dirname -- "$target")/.devsy-vscode.XXXXXX")
    metadata=$(fetch_https "https://update.code.visualstudio.com/api/update/$artifact/stable/latest" | python3 -c '
import json, re, sys
from urllib.parse import urlsplit

release = json.load(sys.stdin)
url, digest = release["url"], release["sha256hash"]
origin = urlsplit(url)
if origin.scheme != "https" or not origin.hostname or origin.username or re.search(r"\s", url):
    raise SystemExit("Invalid VS Code archive URL in Microsoft release metadata")
if not re.fullmatch(r"[0-9a-f]{64}", digest):
    raise SystemExit("Invalid VS Code SHA-256 in Microsoft release metadata")
print(url, digest)
')
    read -r archive_url archive_hash <<< "$metadata"
    archive=$editor_tmp/archive
    printf 'Downloading VS Code Desktop from Microsoft.\n'
    fetch_https --output "$archive" "$archive_url"
    python3 - "$archive" "$archive_hash" <<'PY'
import hashlib, sys

digest = hashlib.sha256()
with open(sys.argv[1], "rb") as archive:
    for chunk in iter(lambda: archive.read(1024 * 1024), b""):
        digest.update(chunk)
if digest.hexdigest() != sys.argv[2]:
    raise SystemExit("VS Code archive failed SHA-256 verification")
PY
    extracted=$editor_tmp/extracted
    mkdir -- "$extracted"
    if [[ $editor_os == Darwin ]]; then
      ditto -x -k "$archive" "$extracted"
      extracted="$extracted/Visual Studio Code.app"
      codesign --verify --deep --strict \
        -R='anchor apple generic and certificate leaf[subject.OU] = "UBF8T346G9"' "$extracted"
    else
      tar -xzf "$archive" --strip-components=1 -C "$extracted"
    fi
    if [[ ! -x $extracted/$cli_relative ]]; then
      printf 'The verified VS Code archive does not contain its desktop CLI.\n' >&2
      return 1
    fi
    mv -- "$extracted" "$target"
    rm -rf -- "$editor_tmp"
    editor_tmp=
  fi
  if [[ ! -e $editor_bin_dir/code && ! -L $editor_bin_dir/code ]]; then
    ln -s -- "$cli_path" "$editor_bin_dir/code"
  fi
  rmdir -- "$editor_install_lock"
  editor_install_lock=
  editor_cli=$cli_path
}

if $with_vscode; then
  editor_cli=$(find_vscode)
  if [[ -z $editor_cli ]]; then install_vscode; fi
  printf 'Using VS Code at %s\n' "$editor_cli"
  editor_extensions=$("$editor_cli" --list-extensions)
  if ! grep -Fxiq 'ms-vscode-remote.remote-ssh' <<< "$editor_extensions"; then
    "$editor_cli" --install-extension ms-vscode-remote.remote-ssh
  fi
  editor_help=$("$editor_cli" --help)
  if [[ $editor_help != *--agents* ]]; then
    printf 'Update VS Code Desktop to use the Agents window and its SSH proxy support.\n' >&2
  fi
fi

if $with_copilot; then
  if command -v copilot >/dev/null 2>&1; then
    copilot_cli=$(command -v copilot)
  else
    copilot_cli=$editor_bin_dir/copilot
    if [[ ! -x $copilot_cli ]]; then
      if [[ -e $copilot_cli || -L $copilot_cli ]]; then
        printf 'Existing path %s is not executable. Move it before retrying.\n' "$copilot_cli" >&2
        exit 1
      fi
      editor_tmp=$(mktemp -d "${TMPDIR:-/tmp}/devsy-copilot.XXXXXX")
      fetch_https --output "$editor_tmp/install.sh" https://gh.io/copilot-install
      env -u GH_TOKEN -u GITHUB_TOKEN -u COPILOT_GITHUB_TOKEN \
        PATH="$editor_bin_dir:$PATH" PREFIX="$editor_prefix" VERSION=latest \
        bash "$editor_tmp/install.sh"
    fi
  fi
  printf 'Using Copilot CLI at %s\n' "$copilot_cli"
  "$copilot_cli" --version
  printf 'For hosted Copilot, sign in separately with copilot login using a GitHub account with Copilot access.\n'
  printf 'For BYOK, configure your model endpoint and credentials before running Copilot.\n'
fi

case :$PATH: in
  *":$editor_bin_dir:"*) ;;
  *) printf 'Add the user tool directory to PATH if needed: %s\n' "$editor_bin_dir" ;;
esac
