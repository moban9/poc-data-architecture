#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# Register the CDC connectors with Kafka Connect — idempotent by COMPARISON,
# not by blind re-PUT.
#
# WHY THIS MATTERS (t_df6a7bb7): every `PUT /connectors/<name>/config` makes
# Connect reconfigure the connector and restart its tasks. A restarted sink task
# rewinds its consumer to the last committed offset, and the Iceberg sink is
# at-least-once, so the replayed window used to be appended to bronze a second
# time. This service runs on every `docker compose up -d`, so a stack that was
# already correctly configured kept re-triggering that replay on every deploy.
#
# Behaviour per connector:
#   1. Render the env-parameterized JSON template (this dir).
#   2. GET /connectors/<name>/config.
#        missing .......... PUT (create)
#        identical ....... skip, no PUT, no task restart
#        different ....... PUT (update) and log exactly which keys differ
#   A PUT is still authoritative: keys dropped from the template are removed.
#
# Usage:
#   ./register-connectors.sh                  # reconcile every connector
#   ./register-connectors.sh iceberg-sink     # one connector (name or file)
#
# Env (all optional — defaults shown):
#   CONNECT_URL            http://localhost:8083
#   FORCE_REGISTER         0        set 1 to PUT unconditionally (config replay)
#   DRY_RUN                0        set 1 to print the plan and change nothing
#   WAIT_FOR_RUNNING       1        after a create/update, wait for RUNNING
#   WAIT_TIMEOUT           120      seconds for that wait
#   IGNORE_EXTRA_KEYS      name     comma-separated keys Connect adds that must
#                                   not count as "config differs"
#   ── Debezium Postgres source ──
#   LMS_DB_HOST            lms-postgres
#   LMS_DB_PORT            5432
#   LMS_DB_USER            lms
#   LMS_DB_PASSWORD        lms
#   LMS_DB_NAME            lms
#   LMS_TOPIC_PREFIX       lms                       (topics become lms.public.*)
#   DBZ_TABLE_INCLUDE_LIST public.loan,public.loan_event,public.borrower,public.repayment_schedule
#   DBZ_SLOT_NAME          lms_poc_debezium
#   DBZ_PUBLICATION_NAME   lms_poc_publication
#   SNAPSHOT_MODE          no_data  Debezium snapshot.mode. DEFAULT no_data on
#                                   purpose: with `initial`, a connector that is
#                                   recreated without offsets re-emits every row
#                                   of every captured table into the same Kafka
#                                   topics, and the append-only Iceberg sink
#                                   writes them to Bronze a second time (the
#                                   2026-11-05 2x repayment_schedule incident).
#                                   no_data means a recreate resumes from the
#                                   WAL and never re-emits history. A NEW
#                                   environment (empty topics) must bootstrap
#                                   with SNAPSHOT_MODE=initial; a deliberate
#                                   re-snapshot goes through resnapshot.sh.
#   ── Iceberg sink (Polaris REST catalog -> MinIO S3) ──
#   ICEBERG_CATALOG_URI    http://polaris:8181/api/catalog
#   ICEBERG_WAREHOUSE      lakehouse                 (MinIO bucket "lakehouse")
#   ICEBERG_TABLES         bronze.loan,bronze.loan_event,bronze.borrower,bronze.repayment_schedule
#   SINK_TOPICS_REGEX      lms.public.*
#   MINIO_ENDPOINT         http://minio:9000
#   MINIO_ROOT_USER        minioadmin
#   MINIO_ROOT_PASSWORD    minioadmin
#   MINIO_PATH_STYLE       true
#   MINIO_REGION           us-east-1
#   POLARIS_CREDENTIAL     root:root                 (client-id:client-secret)
#   POLARIS_SCOPE          PRINCIPAL_ROLE:ALL
#
# Requirements: bash, curl, envsubst (gettext), jq. Without jq the script falls
# back to the old always-PUT behaviour (and says so) — that is safe for a create
# but reintroduces the restart-replay on every deploy.
#
# NOTE: secret values must not contain characters that would break the JSON
# (quotes/backslashes/newlines). The POC defaults are safe.
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

# ── Kafka Connect ────────────────────────────────────────────────────────────
CONNECT_URL="${CONNECT_URL:-http://localhost:8083}"
FORCE_REGISTER="${FORCE_REGISTER:-0}"
DRY_RUN="${DRY_RUN:-0}"
WAIT_FOR_RUNNING="${WAIT_FOR_RUNNING:-1}"
WAIT_TIMEOUT="${WAIT_TIMEOUT:-120}"
IGNORE_EXTRA_KEYS="${IGNORE_EXTRA_KEYS:-name}"

# ── Debezium Postgres source ─────────────────────────────────────────────────
LMS_DB_HOST="${LMS_DB_HOST:-lms-postgres}"
LMS_DB_PORT="${LMS_DB_PORT:-5432}"
LMS_DB_USER="${LMS_DB_USER:-lms}"
LMS_DB_PASSWORD="${LMS_DB_PASSWORD:-lms}"
LMS_DB_NAME="${LMS_DB_NAME:-lms}"
LMS_TOPIC_PREFIX="${LMS_TOPIC_PREFIX:-lms}"
DBZ_TABLE_INCLUDE_LIST="${DBZ_TABLE_INCLUDE_LIST:-public.loan,public.loan_event,public.borrower,public.repayment_schedule}"
DBZ_SLOT_NAME="${DBZ_SLOT_NAME:-lms_poc_debezium}"
DBZ_PUBLICATION_NAME="${DBZ_PUBLICATION_NAME:-lms_poc_publication}"
# no_data = never re-emit history on a connector recreate (docs/09 §4).
SNAPSHOT_MODE="${SNAPSHOT_MODE:-no_data}"

# ── Iceberg sink (Polaris REST catalog -> MinIO S3) ──────────────────────────
ICEBERG_CATALOG_URI="${ICEBERG_CATALOG_URI:-http://polaris:8181/api/catalog}"
ICEBERG_WAREHOUSE="${ICEBERG_WAREHOUSE:-lakehouse}"
ICEBERG_TABLES="${ICEBERG_TABLES:-bronze.loan,bronze.loan_event,bronze.borrower,bronze.repayment_schedule}"
SINK_TOPICS_REGEX="${SINK_TOPICS_REGEX:-lms.public.*}"
MINIO_ENDPOINT="${MINIO_ENDPOINT:-http://minio:9000}"
MINIO_ROOT_USER="${MINIO_ROOT_USER:-minioadmin}"
MINIO_ROOT_PASSWORD="${MINIO_ROOT_PASSWORD:-CHANGE_ME_minio}"
MINIO_PATH_STYLE="${MINIO_PATH_STYLE:-true}"
MINIO_REGION="${MINIO_REGION:-us-east-1}"
POLARIS_CREDENTIAL="${POLARIS_CREDENTIAL:-root:CHANGE_ME_polaris_root}"
POLARIS_SCOPE="${POLARIS_SCOPE:-PRINCIPAL_ROLE:ALL}"

export LMS_DB_HOST LMS_DB_PORT LMS_DB_USER LMS_DB_PASSWORD LMS_DB_NAME \
       LMS_TOPIC_PREFIX DBZ_TABLE_INCLUDE_LIST DBZ_SLOT_NAME DBZ_PUBLICATION_NAME \
       SNAPSHOT_MODE \
       ICEBERG_CATALOG_URI ICEBERG_WAREHOUSE ICEBERG_TABLES SINK_TOPICS_REGEX \
       MINIO_ENDPOINT MINIO_ROOT_USER MINIO_ROOT_PASSWORD MINIO_PATH_STYLE \
       MINIO_REGION POLARIS_CREDENTIAL POLARIS_SCOPE

# Only substitute these variables; any other ${...} in the templates stays intact.
SUBST='${LMS_DB_HOST} ${LMS_DB_PORT} ${LMS_DB_USER} ${LMS_DB_PASSWORD} ${LMS_DB_NAME} ${LMS_TOPIC_PREFIX} ${DBZ_TABLE_INCLUDE_LIST} ${DBZ_SLOT_NAME} ${DBZ_PUBLICATION_NAME} ${SNAPSHOT_MODE} ${ICEBERG_CATALOG_URI} ${ICEBERG_WAREHOUSE} ${ICEBERG_TABLES} ${SINK_TOPICS_REGEX} ${MINIO_ENDPOINT} ${MINIO_ROOT_USER} ${MINIO_ROOT_PASSWORD} ${MINIO_PATH_STYLE} ${MINIO_REGION} ${POLARIS_CREDENTIAL} ${POLARIS_SCOPE}'

command -v envsubst >/dev/null 2>&1 \
  || { echo "!! envsubst (gettext) is required but not installed" >&2; exit 1; }

HAVE_JQ=0
if command -v jq >/dev/null 2>&1; then HAVE_JQ=1; fi

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

# GET the stored config into FETCH_BODY, status into FETCH_STATUS.
# A 404 means "not registered" (create). Any other non-200 aborts the script:
# an auth or 5xx error must never be mistaken for "missing", because that would
# turn a reconcile into a blind re-PUT.
FETCH_STATUS=""
FETCH_BODY=""
fetch_config() {
  local name="$1" out="${TMP_DIR}/$1.json" code
  code="$(curl -sS -o "${out}" -w '%{http_code}' \
            "${CONNECT_URL%/}/connectors/${name}/config" || true)"
  FETCH_STATUS="${code}"
  FETCH_BODY=""
  case "${code}" in
    200) FETCH_BODY="$(cat "${out}")" ;;
    404) : ;;
    *)   echo "!! GET ${name}/config returned HTTP ${code}" >&2
         sed -n '1,5p' "${out}" >&2 || true
         exit 1 ;;
  esac
}

# Print {changed:[keys], removed:[keys]} comparing ONLY the keys we manage: a
# missing key or a different value in the desired config is a change; extra keys
# the worker reports (IGNORE_EXTRA_KEYS) are not.
config_diff() {
  local desired="$1" actual="$2"
  jq -n --argjson d "${desired}" --argjson a "${actual}" --arg ig "${IGNORE_EXTRA_KEYS}" '
    ($ig | split(",") | map(select(length > 0))) as $ignore
    | { changed: [ $d | to_entries[] | select(.value != $a[.key]) | .key ],
        removed: [ ($a | keys[]) as $k
                   | select(($d | has($k)) | not)
                   | select(($ignore | index($k)) == null)
                   | $k ] }'
}

wait_running() {
  local name="$1" state="" deadline=$(( SECONDS + WAIT_TIMEOUT ))
  while [ "${SECONDS}" -lt "${deadline}" ]; do
    state="$(curl -sS "${CONNECT_URL%/}/connectors/${name}/status" 2>/dev/null \
             | jq -r '[.connector.state, (.tasks[]?.state)] | unique | join(",")' \
             2>/dev/null || true)"
    case "${state}" in
      RUNNING) echo "  ✓ ${name} RUNNING"; return 0 ;;
      *FAILED*|*UNASSIGNED*)
        echo "  !! ${name}: ${state} — inspect /connectors/${name}/status (runbook FM1)" >&2
        return 1 ;;
    esac
    sleep 3
  done
  echo "  !! ${name}: still ${state:-unknown} after ${WAIT_TIMEOUT}s (a fresh sink task" >&2
  echo "     needs ~90s to join the control group; see docs/07-cdc-bronze-runbook.md FM3)" >&2
  return 1
}

put_config() {
  local name="$1" body="$2"
  if [ "${DRY_RUN}" = "1" ]; then
    echo "  · dry-run: would PUT ${name}"
    return 0
  fi
  curl -fsS -X PUT \
       -H 'Content-Type: application/json' \
       --data-binary "${body}" \
       "${CONNECT_URL%/}/connectors/${name}/config" >/dev/null
}

register() {
  local file="$1" name body actual delta changed removed
  name="$(basename "${file}" .json)"
  body="$(envsubst "${SUBST}" < "${SCRIPT_DIR}/${file}")"

  if [ "${HAVE_JQ}" = "1" ]; then
    printf '%s' "${body}" | jq -e . >/dev/null \
      || { echo "!! ${file} did not render to valid JSON" >&2; exit 1; }
  fi

  fetch_config "${name}"
  if [ "${FETCH_STATUS}" = "404" ]; then
    echo "→ ${name}: not registered — creating"
    if [ "${DRY_RUN}" = "1" ]; then
      echo "  · dry-run: would create ${name} (no PUT)"
      return 0
    fi
    put_config "${name}" "${body}"
    echo "  ✓ ${name} created"
    [ "${WAIT_FOR_RUNNING}" = "1" ] && wait_running "${name}" || true
    return 0
  fi

  actual="${FETCH_BODY}"

  if [ "${HAVE_JQ}" != "1" ]; then
    echo "!! jq is missing: cannot compare ${name} — falling back to PUT"
    echo "   (each PUT restarts the connector task; install jq to get skip-if-unchanged)"
    put_config "${name}" "${body}"
    return 0
  fi

  delta="$(config_diff "${body}" "${actual}")"
  changed="$(jq -r '.changed | join(", ")' <<<"${delta}")"
  removed="$(jq -r '.removed | join(", ")' <<<"${delta}")"

  if [ -z "${changed}" ] && [ -z "${removed}" ] && [ "${FORCE_REGISTER}" != "1" ]; then
    echo "= ${name}: config unchanged — skipping PUT (no task restart)"
    return 0
  fi

  if [ "${FORCE_REGISTER}" = "1" ] && [ -z "${changed}" ] && [ -z "${removed}" ]; then
    echo "→ ${name}: forced re-PUT (FORCE_REGISTER=1)"
  else
    echo "→ ${name}: config differs — updating"
    [ -n "${changed}" ] && echo "   changed: ${changed}"
    [ -n "${removed}" ] && echo "   removed: ${removed}"
  fi
  if [ "${DRY_RUN}" = "1" ]; then
    echo "  · dry-run: would PUT ${name} (no change applied, no task restart)"
    return 0
  fi
  put_config "${name}" "${body}"
  echo "  ✓ ${name} updated"
  [ "${WAIT_FOR_RUNNING}" = "1" ] && wait_running "${name}" || true
}

files=("$@")
if [ ${#files[@]} -eq 0 ]; then
  files=(debezium-postgres.json iceberg-sink.json)
fi

wait_for_connect "${CONNECT_URL}"

for f in "${files[@]}"; do
  # allow either a connector name ("iceberg-sink") or a filename ("iceberg-sink.json")
  [[ "$f" == *.json ]] || f="${f}.json"
  register "$f"
done

echo "done."
