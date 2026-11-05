#!/bin/bash
# Cancel every QUEUED Dagster run left behind by the */2 dbt_pipeline_schedule.
# Those runs never started (no outputs, no artifacts); the schedule produced them
# faster than a full rebuild can execute, so the queue grew without bound and the
# run coordinator kept launching them 2 at a time.
#
# Usage: ./keel-cancel-queued-runs.sh [--dry-run]
set -u
DRY="${1:-}"
DAGSTER_URL="${DAGSTER_URL:-http://localhost:3001/graphql}"

ids=$(curl -s -X POST "$DAGSTER_URL" -H 'Content-Type: application/json' \
  -d '{"query":"{runsOrError(limit:1000){... on Runs{results{runId status}}}}"}' \
  | jq -r '.data.runsOrError.results[] | select(.status=="QUEUED") | .runId')

n=$(printf '%s\n' "$ids" | grep -c . || true)
echo "queued runs found: $n"
[ "$DRY" = "--dry-run" ] && { printf '%s\n' "$ids" | head -5; exit 0; }

cancelled=0
for id in $ids; do
  r=$(curl -s -X POST "$DAGSTER_URL" -H 'Content-Type: application/json' \
        -d "{\"query\":\"mutation { terminateRun(runId: \\\"$id\\\") { __typename } }\"}")
  case "$r" in
    *TerminateRunSuccess*) cancelled=$((cancelled+1)) ;;
    *) echo "  ! $id -> $r" ;;
  esac
done
echo "cancelled: $cancelled"

remaining=$(curl -s -X POST "$DAGSTER_URL" -H 'Content-Type: application/json' \
  -d '{"query":"{runsOrError(limit:1000){... on Runs{results{runId status}}}}"}' \
  | jq -r '[.data.runsOrError.results[] | select(.status=="QUEUED")] | length')
echo "queued remaining: $remaining"
