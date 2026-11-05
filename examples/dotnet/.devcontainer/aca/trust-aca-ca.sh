#!/usr/bin/env bash
set -euo pipefail

# This bundle is supplied by the ACA sandbox host and mounted read-only. It
# contains multiple roots, which update-ca-certificates needs in separate files.
cert_dir=$(mktemp -d)
trap 'rm -rf "$cert_dir"' EXIT
awk -v out="$cert_dir" '
  /-----BEGIN CERTIFICATE-----/ { file = sprintf("%s/adc-egress-%02d.crt", out, ++count) }
  file { print > file }
  /-----END CERTIFICATE-----/ { close(file); file = "" }
  END { if (!count || file) exit 1 }
' /opt/aca-egress-ca.pem
for cert in "$cert_dir"/*.crt; do
  openssl x509 -in "$cert" -noout
done
install -d -m 0755 /usr/local/share/ca-certificates/devsy-aca
install -m 0644 "$cert_dir"/*.crt /usr/local/share/ca-certificates/devsy-aca/
update-ca-certificates
