#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# Force a FULL re-snapshot of the LMS source so newly added columns/tables are
# re-captured into Bronze.
#
# WHY: Debezium's `snapshot.mode=initial` fires ONCE per logical replication
# slot. Adding columns to `public.loan` (term_months / disbursement_date /
# maturity_date / interest_rate / monthly_installment) or a new table
# `public.repayment_schedule` after the initial snapshot does NOT re-emit the
# existing rows — they are only re-captured on a fresh snapshot.
#
# WHAT IT DOES:
#   1. Deletes the debezium-postgres connector (this also drops its stored
#      offsets, so a re-registration starts clean).
#   2. Drops the logical replication slot + publication in lms-postgres (so
#      Debezium recreates them against the new schema).
#   3. Re-registers both connectors via register-connectors.sh (fresh
#      snapshot.mode=initial).
#
# USAGE (on the VM host, from the compose/ dir):
#   ./connectors/resnapshot.sh
#
# Env overrides (defaults match register-connectors.sh):
#   CONNECT_URL          http://localhost:8083
#   LMS_DB_USER          lms
#   LMS_DB_NAME          lms
#   DBZ_SLOT_NAME        lms_poc_debezium
#   DBZ_PUBLICATION_NAME lms_poc_publication
#   POSTGRES_SERVICE     lms-postgres        (compose service name)
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

CONNECT_URL="${CONNECT_URL:-http://localhost:8083}"
LMS_DB_USER="${LMS_DB_USER:-lms}"
LMS_DB_NAME="${LMS_DB_NAME:-lms}"
DBZ_SLOT_NAME="${DBZ_SLOT_NAME:-lms_poc_debezium}"
DBZ_PUBLICATION_NAME="${DBZ_PUBLICATION_NAME:-lms_poc_publication}"
POSTGRES_SERVICE="${POSTGRES_SERVICE:-lms-postgres}"

cd "${COMPOSE_DIR}"

echo "→ deleting debezium-postgres connector (drops its offsets)"
curl -fsS -X DELETE "${CONNECT_URL%/}/connectors/debezium-postgres" || true
# Give the connector task a moment to release the replication slot.
sleep 5

echo "→ dropping replication slot '${DBZ_SLOT_NAME}' + publication '${DBZ_PUBLICATION_NAME}'"
# An active slot (task still shutting down) cannot be dropped; retry a few times.
for _ in 1 2 3 4 5; do
  if docker compose exec -T "${POSTGRES_SERVICE}" \
      psql -U "${LMS_DB_USER}" -d "${LMS_DB_NAME}" -v ON_ERROR_STOP=0 <<SQL
SELECT pg_drop_replication_slot(slot_name)
  FROM pg_replication_slots WHERE slot_name = '${DBZ_SLOT_NAME}';
DROP PUBLICATION IF EXISTS ${DBZ_PUBLICATION_NAME};
SQL
  then
    break
  fi
  echo "  (slot still active — retrying after 3s)"
  sleep 3
done

echo "→ re-registering the source connector with a DELIBERATE full snapshot"
# The default template is snapshot.mode=no_data (so a plain compose up / connector
# recreate can never re-emit history — docs/09 §4). A re-snapshot is the one case
# that must opt in explicitly, and only for the SOURCE connector.
SNAPSHOT_MODE=initial bash "${SCRIPT_DIR}/register-connectors.sh" debezium-postgres

echo "done. Bronze will re-capture loan + repayment_schedule on the next snapshot."
echo
echo "NOTE: the stored config now says snapshot.mode=initial, so the next"
echo "      ./register-connectors.sh (or compose up) will reconcile it back to"
echo "      no_data — that is intended, and is a no-op for the snapshot once the"
echo "      connector has offsets. Do not re-snapshot a second time by accident."
