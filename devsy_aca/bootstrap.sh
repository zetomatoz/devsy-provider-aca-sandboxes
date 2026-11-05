#!/usr/bin/env bash
# Run as root inside an ACA Ubuntu sandbox. All diagnostics go to stderr so
# provider command stdout remains available for the Devsy byte stream.
set -euo pipefail
exec 1>&2
umask 077

if [[ $(id -u) -ne 0 ]]; then
  printf 'Sandbox bootstrap requires root inside the sandbox.\n'
  exit 1
fi

bootstrap_timeout=${ACA_DOCKER_READY_TIMEOUT:-120}
if [[ ! "$bootstrap_timeout" =~ ^[1-9][0-9]*$ ]]; then
  printf 'ACA_DOCKER_READY_TIMEOUT must be a positive integer number of seconds.\n'
  exit 2
fi

mkdir -p /opt/devsy
if command -v flock >/dev/null 2>&1; then
  exec 9>/opt/devsy/bootstrap.lock
  flock -w "$bootstrap_timeout" 9 || {
    printf 'Timed out waiting for another sandbox bootstrap to finish.\n'
    exit 1
  }
fi

bootstrap_packages=()
if ! command -v docker >/dev/null 2>&1 || ! command -v dockerd >/dev/null 2>&1; then
  bootstrap_packages+=(docker.io)
fi
command -v git >/dev/null 2>&1 || bootstrap_packages+=(git)
command -v curl >/dev/null 2>&1 || bootstrap_packages+=(curl)
[[ -s /etc/ssl/certs/ca-certificates.crt ]] || bootstrap_packages+=(ca-certificates)

if [[ ${#bootstrap_packages[@]} -gt 0 ]]; then
  if ! command -v apt-get >/dev/null 2>&1; then
    printf 'Missing sandbox tools: %s. Use the Ubuntu disk preset or preinstall them in a custom disk.\n' "${bootstrap_packages[*]}"
    exit 1
  fi
  printf 'Installing sandbox prerequisites: %s\n' "${bootstrap_packages[*]}"
  bootstrap_apt_options=(-o Acquire::Retries=1 -o Acquire::http::Timeout=20 -o Acquire::https::Timeout=20)
  timeout --foreground 120s apt-get "${bootstrap_apt_options[@]}" -o APT::Update::Error-Mode=any update
  DEBIAN_FRONTEND=noninteractive apt-get "${bootstrap_apt_options[@]}" -o DPkg::Lock::Timeout=120 install -y --no-install-recommends "${bootstrap_packages[@]}"
fi

bootstrap_socket=unix:///var/run/docker.sock
if timeout 5s docker --host "$bootstrap_socket" info >/dev/null 2>&1; then
  printf 'Sandbox Docker is ready on its Unix socket.\n'
  exit 0
fi

bootstrap_log=/opt/devsy/dockerd.log
bootstrap_started_pid=
# ACA sandboxes have no init system. Keep the daemon detached from the exec
# session. A Unix socket is the only configured listener; do not enable TCP.
if ! pgrep -x dockerd >/dev/null 2>&1; then
  printf 'Starting sandbox Docker on its Unix socket.\n'
  nohup dockerd --host="$bootstrap_socket" >"$bootstrap_log" 2>&1 </dev/null 9>&- &
  bootstrap_started_pid=$!
fi

bootstrap_deadline=$((SECONDS + bootstrap_timeout))
while (( SECONDS < bootstrap_deadline )); do
  if timeout 5s docker --host "$bootstrap_socket" info >/dev/null 2>&1; then
    printf 'Sandbox Docker is ready on its Unix socket.\n'
    exit 0
  fi
  if [[ -n "$bootstrap_started_pid" ]] && ! kill -0 "$bootstrap_started_pid" 2>/dev/null; then
    printf 'Sandbox Docker daemon exited during startup.\n'
    [[ ! -f "$bootstrap_log" ]] || tail -n 60 "$bootstrap_log"
    exit 1
  fi
  sleep 1
done

printf 'Sandbox Docker was not ready after %s seconds.\n' "$bootstrap_timeout"
[[ ! -f "$bootstrap_log" ]] || tail -n 60 "$bootstrap_log"
exit 1
