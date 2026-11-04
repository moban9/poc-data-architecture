#!/usr/bin/env bash
# Generate the RSA keypair Polaris signs JWTs with, so that tokens survive a
# Polaris restart. Idempotent: existing keys are left untouched.
#
# Why: Polaris defaults to an ephemeral keypair generated at boot. Every restart
# therefore invalidates every token already handed out, and long-lived clients
# (Trino's Iceberg REST catalog, dbt, the Iceberg sink) get
#   401 "Failed to verify token"
# until their cached token expires.
#
# Usage:  ./generate-keys.sh          (run before `docker compose up`)
set -euo pipefail
cd "$(dirname "$0")"

mkdir -p keys
if [[ -f keys/private.pem && -f keys/public.pem ]]; then
  echo "keys already present in $(pwd)/keys — leaving untouched"
  exit 0
fi

# PKCS#8 private key + X.509/SPKI public key: exactly what Polaris' PemUtils reads.
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out keys/private.pem 2>/dev/null
openssl pkey -in keys/private.pem -pubout -out keys/public.pem
chmod 644 keys/*.pem
echo "generated $(pwd)/keys/{private,public}.pem"
echo "Polaris mounts ./polaris/keys at /keys (read-only) — see docker-compose.yml."
