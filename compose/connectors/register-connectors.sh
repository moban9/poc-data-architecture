#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# Register the CDC connectors with Kafka Connect (idempotent).
#
# Reads the env-parameterized JSON templates next to this script, fills in the
# `${VAR}` placeholders from the environment (defaults below), and PUTs each
# config to /connectors/<name>/config. PUT = upsert, so re-running updates an
# existing connector instead of failing with a 409.
#
# The connector name is the JSON filename minus the .json extension
# (debezium-postgres.json -> "debezium-postgres", iceberg-sink.json -> "iceberg-sink").
#
# Usage:
#   ./register-connectors.sh                  # register every *.json in this dir
#   ./register-connectors.sh iceberg-sink     # register one connector (name or file)
#
# Requirements: bash, curl, envsubst (gettext). Optional: jq (to pre-validate).
#
# Env vars (all optional — defaults shown):
#   CONNECT_URL            http://localhost:8083
#   ── Debezium Postgres source ──
#   LMS_DB_HOST            lms-postgres
#   LMS_DB_PORT            5432
#   LMS_DB_USER            lms
#   LMS_DB_PASSWORD        lms
#   LMS_DB_NAME            lms
#   LMS_TOPIC_PREFIX       lms                       (topics become lms.public.*)
#   DBZ_TABLE_INCLUDE_LIST public.loan,public.loan_event,public.borrower
#   DBZ_SLOT_NAME          lms_poc_debezium
#   DBZ_PUBLICATION_NAME   lms_poc_publication
#   ── Iceberg sink (Polaris REST catalog -> MinIO S3) ──
#   ICEBERG_CATALOG_URI    http://polaris:8181/api/catalog
#   ICEBERG_WAREHOUSE      s3a://warehouse           (MinIO bucket "warehouse")
#   ICEBERG_TABLES         bronze.loan,bronze.loan_event,bronze.borrower
#   SINK_TOPICS_REGEX      lms.public.*
#   MINIO_ENDPOINT         http://minio:9000
#   MINIO_ROOT_USER        minioadmin
#   MINIO_ROOT_PASSWORD    minioadmin
#   MINIO_PATH_STYLE       true
#   MINIO_REGION           us-east-1
#   POLARIS_CREDENTIAL     root:root                 (client-id:client-secret)
#   POLARIS_SCOPE          PRINCIPAL_ROLE:ALL
#
# NOTE: secret values must not contain characters that would break the JSON
# (quotes/backslashes/newlines). The POC defaults are safe.
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Kafka Connect ────────────────────────────────────────────────────────────
CONNECT_URL="${CONNECT_URL:-http://localhost:8083}"

# ── Debezium Postgres source ─────────────────────────────────────────────────
LMS_DB_HOST="${LMS_DB_HOST:-lms-postgres}"
LMS_DB_PORT="${LMS_DB_PORT:-5432}"
LMS_DB_USER="${LMS_DB_USER:-lms}"
LMS_DB_PASSWORD="${LMS_DB_PASSWORD:-lms}"
LMS_DB_NAME="${LMS_DB_NAME:-lms}"
LMS_TOPIC_PREFIX="${LMS_TOPIC_PREFIX:-lms}"
DBZ_TABLE_INCLUDE_LIST="${DBZ_TABLE_INCLUDE_LIST:-public.loan,public.loan_event,public.borrower}"
DBZ_SLOT_NAME="${DBZ_SLOT_NAME:-lms_poc_debezium}"
DBZ_PUBLICATION_NAME="${DBZ_PUBLICATION_NAME:-lms_poc_publication}"

# ── Iceberg sink (Polaris REST catalog -> MinIO S3) ──────────────────────────
ICEBERG_CATALOG_URI="${ICEBERG_CATALOG_URI:-http://polaris:8181/api/catalog}"
ICEBERG_WAREHOUSE="${ICEBERG_WAREHOUSE:-s3a://warehouse}"
ICEBERG_TABLES="${ICEBERG_TABLES:-bronze.loan,bronze.loan_event,bronze.borrower}"
SINK_TOPICS_REGEX="${SINK_TOPICS_REGEX:-lms.public.*}"
MINIO_ENDPOINT="${MINIO_ENDPOINT:-http://minio:9000}"
MINIO_ROOT_USER="${MINIO_ROOT_USER:-minioadmin}"
MINIO_ROOT_PASSWORD="${MINIO_ROOT_PASSWORD:-minioadmin}"
MINIO_PATH_STYLE="${MINIO_PATH_STYLE:-true}"
MINIO_REGION="${MINIO_REGION:-us-east-1}"
POLARIS_CREDENTIAL="${POLARIS_CREDENTIAL:-root:root}"
POLARIS_SCOPE="${POLARIS_SCOPE:-PRINCIPAL_ROLE:ALL}"

export LMS_DB_HOST LMS_DB_PORT LMS_DB_USER LMS_DB_PASSWORD LMS_DB_NAME \
       LMS_TOPIC_PREFIX DBZ_TABLE_INCLUDE_LIST DBZ_SLOT_NAME DBZ_PUBLICATION_NAME \
       ICEBERG_CATALOG_URI ICEBERG_WAREHOUSE ICEBERG_TABLES SINK_TOPICS_REGEX \
       MINIO_ENDPOINT MINIO_ROOT_USER MINIO_ROOT_PASSWORD MINIO_PATH_STYLE \
       MINIO_REGION POLARIS_CREDENTIAL POLARIS_SCOPE

# Only substitute these variables; any other ${...} in the templates stays intact.
SUBST='${LMS_DB_HOST} ${LMS_DB_PORT} ${LMS_DB_USER} ${LMS_DB_PASSWORD} ${LMS_DB_NAME} ${LMS_TOPIC_PREFIX} ${DBZ_TABLE_INCLUDE_LIST} ${DBZ_SLOT_NAME} ${DBZ_PUBLICATION_NAME} ${ICEBERG_CATALOG_URI} ${ICEBERG_WAREHOUSE} ${ICEBERG_TABLES} ${SINK_TOPICS_REGEX} ${MINIO_ENDPOINT} ${MINIO_ROOT_USER} ${MINIO_ROOT_PASSWORD} ${MINIO_PATH_STYLE} ${MINIO_REGION} ${POLARIS_CREDENTIAL} ${POLARIS_SCOPE}'

wait_for_connect() {
  local url="${1%/}"
  echo "→ waiting for Kafka Connect at ${url} ..."
  for _ in $(seq 1 60); do
    if curl -fsS "${url}/" >/dev/null 2>&1; then
      echo "✓ connect is up"
      return 0
    fi
    sleep 2
  done
  echo "!! Kafka Connect not reachable at ${url} after 120s" >&2
  return 1
}

register() {
  local file="$1"
  local name body
  name="$(basename "$file" .json)"
  body="$(envsubst "$SUBST" < "${SCRIPT_DIR}/${file}")"

  if command -v jq >/dev/null 2>&1; then
    printf '%s' "$body" | jq -e . >/dev/null \
      || { echo "!! ${file} did not render to valid JSON" >&2; exit 1; }
  fi

  echo "→ registering '${name}' (${file})"
  curl -fsS -X PUT \
       -H 'Content-Type: application/json' \
       --data-binary "$body" \
       "${CONNECT_URL%/}/connectors/${name}/config" \
    && echo "✓ ${name} registered"
}

command -v envsubst >/dev/null 2>&1 \
  || { echo "!! envsubst (gettext) is required but not installed" >&2; exit 1; }

files=("$@")
if [ ${#files[@]} -eq 0 ]; then
  files=(debezium-postgres.json iceberg-sink.json)
fi

wait_for_connect "$CONNECT_URL"

for f in "${files[@]}"; do
  # allow either a connector name ("iceberg-sink") or a filename ("iceberg-sink.json")
  [[ "$f" == *.json ]] || f="${f}.json"
  register "$f"
done

echo "done."
