#!/bin/sh
# Run the dbt medallion pipeline (seed + run + test) and push the results to
# the Prometheus pushgateway so Grafana's pipeline_stage_health (Bronze/Silver/
# Gold), quarantine-count and dbt-test panels light up.
#
# One-command re-run:
#   sh scripts/run-and-push-metrics.sh
#
# Environment:
#   DBT_PROFILES_DIR   where profiles.yml lives (default: the dbt project dir)
#   TRINO_HOST         Trino host (default: trino — the compose service name)
#   PUSHGATEWAY_URL    pushgateway base URL (default: http://pushgateway:9091)
#
# dbt test is EXPECTED to report failures on the dirty source data (that is the
# DQ gate doing its job — bad rows are quarantined and the failing tests are
# pushed as dbt_test_failures). The run itself (silver + gold) must succeed.
set -u

cd "$(dirname "$0")/.."
HERE="$(pwd)"
DBT_PROFILES_DIR="${DBT_PROFILES_DIR:-$HERE}"
TRINO_HOST="${TRINO_HOST:-trino}"
PUSHGATEWAY_URL="${PUSHGATEWAY_URL:-http://pushgateway:9091}"

echo "=== dbt seed (first run only) ==="
# The Polaris/Iceberg catalog cannot DROP + recreate existing tables, so
# re-seeding an existing table fails. Seeds are demo fixtures (not used by the
# production Silver models) — seed once, skip on subsequent runs.
SEED_PRESENT=$(python3 scripts/trino_query.py \
  "SELECT count(*) AS c FROM lakehouse.bronze.dirty_data" \
  --host "$TRINO_HOST" 2>/dev/null | python3 -c "import sys,json; d=json.load(sys.stdin); print(d[0][0] if d else '')" 2>/dev/null || true)
if [ -z "$SEED_PRESENT" ]; then
  dbt seed --profiles-dir "$DBT_PROFILES_DIR" || echo "seed step failed (non-fatal)"
else
  echo "seed tables already present (dirty_data rows=$SEED_PRESENT) — skipping dbt seed"
fi

echo "=== dbt run (silver + gold) ==="
if ! dbt run --profiles-dir "$DBT_PROFILES_DIR"; then
  echo "FATAL: dbt run failed — not pushing metrics"
  exit 1
fi

echo "=== dbt test (failures are expected on dirty source data) ==="
set +e
dbt test --profiles-dir "$DBT_PROFILES_DIR" 2>&1
TEST_RC=$?
set -e
echo "dbt test exit code: $TEST_RC"

# Parse the last run's results: count only DATA TEST nodes that failed/errored
# (exclude the on-run-end hook operation from the failure count).
TEST_FAILURES=$(python3 - <<'PY'
import json
rr = json.load(open("target/run_results.json"))
print(sum(1 for r in rr.get("results", [])
          if r.get("unique_id", "").startswith("test.")
          and r.get("status") in ("fail", "error")))
PY
)
TEST_TOTAL=$(python3 - <<'PY'
import json
rr = json.load(open("target/run_results.json"))
print(sum(1 for r in rr.get("results", []) if r.get("unique_id", "").startswith("test.")))
PY
)

# Quarantine rows currently held in lakehouse.quarantine_lms.quarantine_lms.
QUARANTINE=$(python3 scripts/trino_query.py \
  "SELECT count(*) AS c FROM lakehouse.quarantine_lms.quarantine_lms" \
  --host "$TRINO_HOST" | python3 -c "import sys,json; print(json.load(sys.stdin)[0][0])")

echo "dbt_test_failures=$TEST_FAILURES dbt_tests_total=$TEST_TOTAL quarantine_rows_total=$QUARANTINE"

# Push to the pushgateway (PUT replaces the last run's values rather than
# appending). Uses Python stdlib — the dbt container image has no curl.
TEST_FAILURES="$TEST_FAILURES" TEST_TOTAL="$TEST_TOTAL" QUARANTINE="$QUARANTINE" \
PUSHGATEWAY_URL="$PUSHGATEWAY_URL" python3 - <<'PY'
import os, urllib.request

metrics = "\n".join([
    'dbt_run_success{layer="bronze"} 1',
    'dbt_run_success{layer="silver"} 1',
    'dbt_run_success{layer="gold"} 1',
    f'dbt_test_failures {os.environ["TEST_FAILURES"]}',
    f'dbt_tests_total {os.environ["TEST_TOTAL"]}',
    f'quarantine_rows_total {os.environ["QUARANTINE"]}',
]) + "\n"

url = os.environ["PUSHGATEWAY_URL"].rstrip("/") + "/metrics/job/dbt/instance/lms-poc-dbt"
req = urllib.request.Request(url, data=metrics.encode(), method="PUT")
urllib.request.urlopen(req, timeout=30)
print(f"=== pushed to {url} ===")
print(metrics)
PY

echo "=== done ==="
