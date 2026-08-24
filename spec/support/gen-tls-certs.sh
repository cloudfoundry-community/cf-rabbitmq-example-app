#!/usr/bin/env bash
# Generates the certificates docker-compose.test.yml mounts into the TLS
# broker. Run before `docker compose -f docker-compose.test.yml up`; the
# output is git-ignored, so every checkout makes its own.
#
# Two certificates, both from the same throwaway CA:
#
#   server.crt  CN=localhost, SAN localhost + 127.0.0.1 - the one that
#               should verify.
#   wrong.crt   CN=wrong.example.invalid - a certificate that chains to a
#               trusted CA but names a different host. That is the case
#               that separates "checks the chain" from "checks who it is
#               talking to", and four of this app's six TLS protocols
#               used to accept it.
set -euo pipefail

dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/tls"
mkdir -p "$dir"
cd "$dir"

if [ -f ca.crt ] && [ -f server.crt ] && [ -f wrong.crt ]; then
  echo "spec/support/tls: certificates already present; delete the directory to regenerate"
  exit 0
fi

openssl req -x509 -newkey rsa:2048 -sha256 -days 365 -nodes \
  -keyout ca.key -out ca.crt -subj "/CN=cf-rabbitmq-example-app-test-ca" \
  -addext "basicConstraints=critical,CA:TRUE" 2>/dev/null

issue() {
  local name="$1" subject="$2" san="$3"
  openssl req -newkey rsa:2048 -nodes -keyout "$name.key" -out "$name.csr" \
    -subj "$subject" 2>/dev/null
  printf 'subjectAltName=%s\nextendedKeyUsage=serverAuth\n' "$san" > "$name.ext"
  openssl x509 -req -in "$name.csr" -CA ca.crt -CAkey ca.key -CAcreateserial \
    -out "$name.crt" -days 365 -sha256 -extfile "$name.ext" 2>/dev/null
  rm -f "$name.csr" "$name.ext"
  # The broker runs as a non-root user inside the container and reads
  # these straight off the mount.
  chmod 644 "$name.key" "$name.crt"
}

issue server "/CN=localhost" "DNS:localhost,IP:127.0.0.1"
issue wrong  "/CN=wrong.example.invalid" "DNS:wrong.example.invalid"
chmod 644 ca.crt

echo "spec/support/tls: wrote ca.crt, server.crt, wrong.crt"
