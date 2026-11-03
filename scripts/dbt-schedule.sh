#!/bin/bash
# Re-run the dbt medallion pipeline (seed + silver + gold + test) and push the
# results to the pushgateway so Grafana's quarantine / dbt-test / Bronze-Silver-
# Gold panels track the latest data. Scheduled by cron on the VM.
#
# Idempotent + overlap-safe: a lock file prevents two runs stacking when a run
# takes longer than the cron interval.
set -euo pipefail

LOCK=/tmp/dbt-schedule.lock
if [ -e "$LOCK" ]; then
    echo "[$(date -u +%FT%TZ)] previous dbt run still in progress — skipping"
    exit 0
fi
trap 'rm -f "$LOCK"' EXIT
touch "$LOCK"

cd "$(dirname "$0")/../compose"
docker compose -f docker-compose.yml -f monitoring.yml -f traefik.yml up -d --force-recreate dbt
