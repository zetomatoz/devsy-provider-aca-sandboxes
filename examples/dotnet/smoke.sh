#!/usr/bin/env bash
set -euo pipefail
cd -- "$(dirname -- "$0")"

dotnet build --nologo --configuration Debug
smoke_log=$(mktemp "${TMPDIR:-/tmp}/devsy-dotnet-smoke.XXXXXX")
dotnet bin/Debug/net10.0/SandboxHello.dll --urls http://127.0.0.1:0 >"$smoke_log" 2>&1 &
smoke_pid=$!
trap 'kill "$smoke_pid" 2>/dev/null || true; wait "$smoke_pid" 2>/dev/null || true; rm -f "$smoke_log"' EXIT

for smoke_attempt in {1..60}; do
  if ! kill -0 "$smoke_pid" 2>/dev/null; then
    cat "$smoke_log" >&2
    exit 1
  fi
  smoke_url=$(sed -n 's/.*Now listening on: \(http:\/\/127\.0\.0\.1:[0-9][0-9]*\).*/\1/p' "$smoke_log")
  if [[ -n "$smoke_url" ]] && smoke_body=$(curl --fail --silent "$smoke_url/health"); then
    [[ "$smoke_body" == '{"status":"ok"}' ]]
    smoke_greeting=$(curl --fail --silent "$smoke_url/")
    [[ "$smoke_greeting" == '{"message":"Hello from the Devsy ACA sandbox!"}' ]]
    printf 'PASS: .NET build, /health, and / HTTP responses\n'
    exit 0
  fi
  sleep 0.25
done

cat "$smoke_log" >&2
printf 'Application did not become healthy in time.\n' >&2
exit 1
