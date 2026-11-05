#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: scripts/install-tools.sh [--check]

Install missing local tools for the ACA provider: Python 3.10+ with venv,
Azure CLI, Devsy, the ACA Sandbox CLI, and OpenSSH. Use --check to report
readiness without installing anything or signing in to Azure.

Automatic installation supports Apple Silicon macOS with Homebrew and
x86-64 Ubuntu 22.04/24.04/26.04 or Debian 12. On a new Mac, the Homebrew
installer can prompt for administrator access. Linux package installation
requires sudo or root. Devsy and aca are installed under ~/.local/bin.
USAGE
}

check_only=false
case "${1:-}" in
  --check) check_only=true; shift ;;
  -h|--help) usage; exit 0 ;;
esac
if (($#)); then usage >&2; exit 2; fi

fail() {
  printf '%s\n' "$*" >&2
  exit 1
}

host_os=$(uname -s)
host_arch=$(uname -m)
case "$host_os:$host_arch" in
  Darwin:arm64|Darwin:aarch64) devsy_asset=devsy-darwin-arm64 ;;
  Linux:x86_64|Linux:amd64) devsy_asset=devsy-linux-amd64 ;;
  *) fail "The ACA Sandbox CLI has macOS Apple Silicon and Linux x86-64 builds for this setup. Detected $host_os $host_arch. On an Apple Silicon Mac, run this in a native terminal. On Windows x86-64, use Ubuntu under WSL2 for the headless workflow." ;;
esac

user_bin="$HOME/.local/bin"
export PATH="$PATH:$user_bin"
if [[ $host_os == Darwin && -x /opt/homebrew/bin/brew ]]; then
  export PATH="/opt/homebrew/bin:$PATH"
fi

python_bin=${PYTHON:-python3}
devsy_bin=${DEVSY_BIN:-devsy}
scratch=$(mktemp -d "${TMPDIR:-/tmp}/devsy-aca-tools.XXXXXXXX")
trap 'rm -rf -- "$scratch"' EXIT

python_ready() {
  command -v "$python_bin" >/dev/null 2>&1 &&
    "$python_bin" -c 'import sys; sys.exit(sys.version_info < (3, 10))' >/dev/null 2>&1 &&
    "$python_bin" -m venv --clear "$scratch/venv" >/dev/null 2>&1 &&
    "$scratch/venv/bin/python" -m pip --version >/dev/null 2>&1
}

need_python=false
python_ready || need_python=true

report_tool() {
  local name=$1
  shift
  local version
  if version=$("$@" 2>/dev/null); then
    printf '  %s: %s\n' "$name" "$version"
  else
    printf '  %s: missing or failed to run\n' "$name" >&2
    return 1
  fi
}

report_tools() {
  local result=0
  if [[ $need_python == true ]]; then
    printf '  Python: Python 3.10+ with a working venv and pip is required\n' >&2
    result=1
  else
    report_tool Python "$python_bin" --version || result=1
  fi
  report_tool 'Azure CLI' az version --query '"azure-cli"' --output tsv || result=1
  report_tool Devsy "$devsy_bin" --version || result=1
  report_tool 'ACA CLI' aca --version || result=1
  if ! command -v ssh >/dev/null 2>&1; then
    printf '  OpenSSH: missing\n' >&2
    result=1
  else
    printf '  OpenSSH: %s\n' "$(command -v ssh)"
  fi
  return "$result"
}

if [[ $check_only == true ]]; then
  report_tools
  exit
fi

if [[ -n ${PYTHON:-} && $need_python == true ]]; then
  fail "PYTHON points to an interpreter without a working Python 3.10+ venv. Fix PYTHON or unset it and rerun the installer."
fi
if [[ -n ${DEVSY_BIN:-} ]] && ! command -v "$devsy_bin" >/dev/null 2>&1; then
  fail "DEVSY_BIN points to a missing executable. Fix DEVSY_BIN or unset it and rerun the installer."
fi

download() {
  curl --disable --proto '=https' --proto-redir '=https' --tlsv1.2 \
    --connect-timeout 15 --max-time 900 -fsSL --output "$2" "$1"
}

install_mac_packages() {
  local packages=()
  [[ $need_python == false ]] || packages+=(python)
  command -v az >/dev/null 2>&1 || packages+=(azure-cli)
  if ((${#packages[@]} == 0)); then return; fi
  command -v curl >/dev/null 2>&1 || fail 'Install the macOS command line tools to get curl.'
  if ! command -v brew >/dev/null 2>&1; then
    printf 'Installing Homebrew from its official installer.\n'
    download https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh "$scratch/brew-install.sh"
    /bin/bash "$scratch/brew-install.sh"
    export PATH="/opt/homebrew/bin:$PATH"
  fi
  brew install "${packages[@]}"
}

as_root() {
  if ((EUID == 0)); then "$@"; else sudo "$@"; fi
}

install_linux_packages() {
  local packages=()
  local need_azure=false
  if ! command -v az >/dev/null 2>&1; then
    need_azure=true
    packages+=(ca-certificates curl gnupg)
  elif ! command -v curl >/dev/null 2>&1; then
    packages+=(ca-certificates curl)
  fi
  [[ $need_python == false ]] || packages+=(python3 python3-venv)
  command -v ssh >/dev/null 2>&1 || packages+=(openssh-client)
  if ((${#packages[@]} == 0)); then return; fi

  local ID VERSION_CODENAME
  # This OS-owned file defines the distro's apt suite.
  [[ -r /etc/os-release ]] || fail 'Cannot identify this Linux distribution. Install the missing tools with your distribution package manager.'
  . /etc/os-release
  case "${ID:-}:${VERSION_CODENAME:-}" in
    ubuntu:jammy|ubuntu:noble|ubuntu:resolute|debian:bookworm) ;;
    *) fail 'Automatic package setup requires Ubuntu 22.04/24.04/26.04 or Debian 12. Install Azure CLI, curl, OpenSSH, and Python 3.10+ with venv for your distribution, then rerun this installer. Azure CLI guide: https://learn.microsoft.com/en-us/cli/azure/install-azure-cli-linux' ;;
  esac
  if ((EUID != 0)); then
    command -v sudo >/dev/null 2>&1 || fail 'Installing Linux packages requires sudo or root access.'
  fi
  as_root apt-get update
  as_root apt-get install -y --no-install-recommends "${packages[@]}"
  if [[ $need_azure == false ]]; then return; fi

  # Use Microsoft's scoped signing key and apt repository. Preserve an Azure
  # CLI source if one already exists on the machine.
  if ! grep -qsF 'packages.microsoft.com/repos/azure-cli' /etc/apt/sources.list \
      /etc/apt/sources.list.d/*.list /etc/apt/sources.list.d/*.sources; then
    download https://packages.microsoft.com/keys/microsoft.asc "$scratch/microsoft.asc"
    gpg --batch --dearmor --output "$scratch/microsoft.gpg" "$scratch/microsoft.asc"
    as_root install -d -m 0755 /etc/apt/keyrings
    as_root install -m 0644 "$scratch/microsoft.gpg" /etc/apt/keyrings/devsy-aca-microsoft.gpg
    cat >"$scratch/azure-cli.sources" <<SOURCE
Types: deb
URIs: https://packages.microsoft.com/repos/azure-cli/
Suites: $VERSION_CODENAME
Components: main
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/devsy-aca-microsoft.gpg
SOURCE
    as_root install -m 0644 "$scratch/azure-cli.sources" /etc/apt/sources.list.d/devsy-aca-azure-cli.sources
    as_root apt-get update
  fi
  as_root apt-get install -y --no-install-recommends azure-cli
}

if [[ $host_os == Darwin ]]; then install_mac_packages; else install_linux_packages; fi
if [[ $need_python == true ]] && python_ready; then need_python=false; fi

if ! command -v "$devsy_bin" >/dev/null 2>&1; then
  # This is the version verified with the provider. The upstream Homebrew
  # formula and GitHub release metadata publish these same SHA-256 digests.
  devsy_version=v1.26.0
  case "$devsy_asset" in
    devsy-darwin-arm64) devsy_sha=6f2807bdc14ffd5d01744a3cff3c3788cb1e42fd17a8f482ad639e1f1b6a503c ;;
    devsy-linux-amd64) devsy_sha=93ea26c5dc0d17f3e17aafc873f751f556e2879e2a9cdb7a3ff158ddbd16a3f0 ;;
  esac
  printf 'Installing Devsy %s.\n' "$devsy_version"
  download "https://github.com/devsy-org/devsy/releases/download/$devsy_version/$devsy_asset" "$scratch/devsy"
  if command -v sha256sum >/dev/null 2>&1; then
    printf '%s  %s\n' "$devsy_sha" "$scratch/devsy" | sha256sum --check
  else
    printf '%s  %s\n' "$devsy_sha" "$scratch/devsy" | shasum -a 256 --check
  fi
  mkdir -p "$user_bin"
  install -m 0755 "$scratch/devsy" "$user_bin/devsy"
fi

if ! command -v aca >/dev/null 2>&1; then
  printf 'Installing the ACA Sandbox CLI with Microsoft’s checksum-verifying installer.\n'
  mkdir -p "$user_bin"
  download https://aka.ms/aca-cli-install "$scratch/aca-install.sh"
  INSTALL_DIR="$user_bin" /bin/sh "$scratch/aca-install.sh"
fi

report_tools
printf '\nIn your shell, add the user bin directory to PATH:\n  export PATH="$HOME/.local/bin:$PATH"\n'
if [[ $host_os == Darwin && -x /opt/homebrew/bin/brew ]]; then
  printf 'If Homebrew was just installed, also run:\n  eval "$(/opt/homebrew/bin/brew shellenv)"\n'
fi
