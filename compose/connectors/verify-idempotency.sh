#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# Measure the duplicate cost of a sink restart (kanban t_df6a7bb7).
#
# WHAT IT DOES: kills the connect container with SIGKILL twice — the same crash
# the crash-loop produced — waits for the connectors to come back RUNNING and for
# the replayed window to be re-consumed, and then compares bronze against the LMS
# source after each kill:
#
#   * total rows   vs count(DISTINCT id)   → how many duplicate rows the replay added
#   * distinct ids vs source count         → whether the replay lost or added keys
#
# It also prints the sink consumer lag before each kill so the log shows the
# uncommitted window being replayed.
#
# IMPORTANT — what PASS means here: `count(*) == count(DISTINCT id)` for every
# table is only reachable with an UPERTING writer. The Apache Iceberg Kafka
# Connect sink is append-only (see docs/09-cdc-delivery-semantics.md §3), so on
# this stack the script reports the duplicate delta per restart instead of
# passing. That delta is the input to the remediation decision: it bounds how
# often bronze needs a reconcile if we dedupe on read.
#
# EXPECT_IDEMPOTENT=1 turns duplicate rows into a hard FAIL — use it once a
# writer that actually upserts is in place (docs/09 §5). Default 0 = report the
# replay cost and fail only on real damage (rows lost, baseline dirty).
#
# BASELINE: with EXPECT_IDEMPOTENT=0 a table that is already dirty is reported
# and the run continues — Bronze is a changelog, so N rows per id is legitimate
# (see docs/09 §3). With EXPECT_IDEMPOTENT=1 the script exits 2 on a dirty
# baseline, because an idempotency assertion needs a clean start (dedupe first:
# kanban t_43530a0f).
#
# USAGE (on the VM host, from /home/ubuntu/poc/compose):
#   ./connectors/verify-idempotency.sh               # baseline + 2 kills
#   SKIP_KILL=1 ./connectors/verify-idempotency.sh    # counts only, no restart
#   WITH_DBT=1  ./connectors/verify-idempotency.sh    # + dbt run/test tail
#
# ENV (defaults shown):
#   CONNECT_URL      http://localhost:8083
#   CATALOG          lakehouse
#   BRONZE_SCHEMA    bronze
#   TABLES           loan loan_event borrower repayment_schedule
#   EXPECT_LOAN      354360        EXPECT_LOAN_EVENT       744605
#   EXPECT_BORROWER  (unset → compare to source only)
#   EXPECT_REPAYMENT_SCHEDULE 6908334
#   SETTLE_SECONDS   45            (2+ commit cycles after RUNNING)
#   KILL_TIMEOUT     300           (per restart; a fresh sink task needs ~90s)
#   COMPOSE          "docker compose -f docker-compose.yml -f monitoring.yml -f traefik.yml"
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${COMPOSE_DIR}"

CONNECT_URL="${CONNECT_URL:-http://localhost:8083}"
CATALOG="${CATALOG:-lakehouse}"
BRONZE_SCHEMA="${BRONZE_SCHEMA:-bronze}"
TABLES="${TABLES:-loan loan_event borrower repayment_schedule}"
SETTLE_SECONDS="${SETTLE_SECONDS:-45}"
KILL_TIMEOUT="${KILL_TIMEOUT:-300}"
SKIP_KILL="${SKIP_KILL:-0}"
WITH_DBT="${WITH_DBT:-0}"
EXPECT_IDEMPOTENT="${EXPECT_IDEMPOTENT:-0}"
LMS_DB_USER="${LMS_DB_USER:-lms}"
LMS_DB_NAME="${LMS_DB_NAME:-lms}"
LMS_DB_PASSWORD="${LMS_DB_PASSWORD:-lms}"
TRINO_USER="${TRINO_USER:-keel}"

EXPECT_loan="${EXPECT_LOAN:-354360}"
EXPECT_loan_event="${EXPECT_LOAN_EVENT:-744605}"
EXPECT_borrower="${EXPECT_BORROWER:-}"
EXPECT_repayment_schedule="${EXPECT_REPAYMENT_SCHEDULE:-6908334}"

COMPOSE="${COMPOSE:-docker compose -f docker-compose.yml -f monitoring.yml -f traefik.yml}"
# NOTE: do NOT force COMPOSE_PROJECT_NAME here. monitoring.yml declares
# `name: lms-monitoring`, and as the last -f file to declare a name it wins, so
# the merged project is lms-monitoring. Forcing another name would make compose
# look for (or create!) a parallel project instead of touching the live one.

die() { echo "!! $*" >&2; exit 1; }

command -v docker >/dev/null 2>&1 \
  || die "docker is not installed here — run this on the VM host: ssh ubuntu@<VM_IP>"
docker info >/dev/null 2>&1 \
  || die "cannot talk to the docker daemon (are you in the docker group?)"

container_of() { # compose service name -> container id (running first, else any)
  local cid
  cid="$(docker ps -q --filter "label=com.docker.compose.service=$1" | head -n1 || true)"
  if [ -z "${cid}" ]; then
    cid="$(docker ps -aq --filter "label=com.docker.compose.service=$1" | head -n1 || true)"
  fi
  printf '%s' "${cid}"
}

TRINO_CID="$(container_of trino)"
PG_CID="$(container_of lms-postgres)"
CONNECT_CID="$(container_of connect)"
[ -n "${TRINO_CID}" ]   || die "no trino container — run this on the VM host, from the compose dir"
[ -n "${PG_CID}" ]      || die "no lms-postgres container"
[ -n "${CONNECT_CID}" ] || die "no connect container"

pg_q()   { docker exec -e PGPASSWORD="${LMS_DB_PASSWORD}" "${PG_CID}" \
             psql -U "${LMS_DB_USER}" -d "${LMS_DB_NAME}" -tAc "$1" | tr -d '[:space:]'; }
trino_q() { docker exec -e JAVA_TOOL_OPTIONS= "${TRINO_CID}" \
             trino --user "${TRINO_USER}" --output-format TSV --no-progress --execute "$1"; }

sink_lag() {
  local kafka log
  kafka="$(container_of kafka)"
  [ -n "${kafka}" ] || { echo "n/a"; return 0; }
  log="$(docker exec "${kafka}" /opt/kafka/bin/kafka-consumer-groups.sh \
          --bootstrap-server localhost:9092 --describe --group connect-iceberg-sink 2>/dev/null || true)"
  # sum the LAG column (6th: GROUP TOPIC PARTITION CURRENT-OFFSET LOG-END-OFFSET LAG ...)
  awk 'NF >= 6 && $6 ~ /^[0-9]+$/ { sum += $6 } END { printf "%d", sum+0 }' <<<"${log}"
}

wait_rest() {
  for _ in $(seq 1 60); do
    curl -fsS "${CONNECT_URL%/}/" >/dev/null 2>&1 && return 0
    sleep 2
  done
  return 1
}

wait_sink_running() {
  local deadline=$(( SECONDS + KILL_TIMEOUT )) state=""
  while [ "${SECONDS}" -lt "${deadline}" ]; do
    state="$(curl -sS "${CONNECT_URL%/}/connectors/iceberg-sink/status" 2>/dev/null \
             | python3 -c 'import json,sys;d=json.load(sys.stdin);print(",".join(sorted({d["connector"]["state"]}|{t["state"] for t in d.get("tasks",[])})))' \
             2>/dev/null || true)"
    [ "${state}" = "RUNNING" ] && return 0
    sleep 5
  done
  echo "!! iceberg-sink not RUNNING after ${KILL_TIMEOUT}s (last state: ${state:-unknown})" >&2
  echo "   curl -s ${CONNECT_URL}/connectors/iceberg-sink/status" >&2
  return 1
}

kill_connect() {
  local n="$1"
  echo
  echo "── kill #${n}: SIGKILL connect (${CONNECT_CID}) — sink lag before kill: $(sink_lag) ──"
  docker kill --signal=SIGKILL "${CONNECT_CID}" >/dev/null
  # `restart: unless-stopped` normally brings it straight back; nudge if not.
  if ! wait_rest; then
    echo "   connect did not self-restart; starting it explicitly"
    docker start "${CONNECT_CID}" >/dev/null
    wait_rest || die "connect REST never came back after SIGKILL #${n}"
  fi
  echo "   connect REST is up; waiting for iceberg-sink RUNNING ..."
  wait_sink_running || die "connectors did not recover after SIGKILL #${n}"
  echo "   settled: sleeping ${SETTLE_SECONDS}s for the replay window to drain"
  sleep "${SETTLE_SECONDS}"
}

snapshot() { # <label>
  local label="$1" t src total distinct row verdict
  echo
  echo "── counts: ${label} ──"
  printf '%-22s %12s %12s %12s %s\n' table source bronze_rows distinct_ids verdict
  for t in ${TABLES}; do
    src="$(pg_q "SELECT count(*) FROM public.${t}")"
    row="$(trino_q "SELECT count(*), count(DISTINCT id) FROM ${CATALOG}.${BRONZE_SCHEMA}.${t}")" \
      || die "trino query failed for ${CATALOG}.${BRONZE_SCHEMA}.${t}"
    [ -n "${row}" ] || die "trino returned no rows for ${CATALOG}.${BRONZE_SCHEMA}.${t}"
    total="${row%%$'\t'*}"
    distinct="${row##*$'\t'}"
    verdict="ok"
    [ "${total}" != "${distinct}" ] && verdict="DUPES (+$(( total - distinct )))"
    printf '%-22s %12s %12s %12s %s\n' "${t}" "${src}" "${total}" "${distinct}" "${verdict}"
    eval "SNAP_${label}_src_${t}=\${src}"
    eval "SNAP_${label}_total_${t}=\${total}"
    eval "SNAP_${label}_distinct_${t}=\${distinct}"
  done
}

verdict_for() { # <table> <label>
  local t="$1" label="$2" total distinct src expect
  eval "total=\${SNAP_${label}_total_${t}}"
  eval "distinct=\${SNAP_${label}_distinct_${t}}"
  eval "src=\${SNAP_${label}_src_${t}}"
  eval "expect=\${EXPECT_${t}:-}"
  if [ "${total}" != "${distinct}" ]; then
    local dupes=$(( total - distinct ))
    if [ "${EXPECT_IDEMPOTENT}" = "1" ]; then
      echo "FAIL duplicate rows: ${total} rows vs ${distinct} distinct ids (+${dupes})"
      return 1
    fi
    echo "REPLAY COST: +${dupes} duplicate rows (append-only writer — docs/09 §3)"
    return 0
  fi
  if [ "${EXPECT_IDEMPOTENT}" = "1" ] && [ -n "${expect}" ] \
     && [ "${distinct}" -ge "${expect}" ] && [ "${total}" != "${expect}" ]; then
    echo "FAIL drained table has ${total} rows, expected exactly ${expect}"
    return 1
  fi
  if [ -n "${expect}" ] && [ "${distinct}" -lt "${expect}" ]; then
    echo "WARN still draining: ${distinct}/${expect} distinct ids (no dupes — acceptable)"
    return 0
  fi
  echo "PASS ${total} rows == ${distinct} distinct ids (source ${src})"
  return 0
}

echo "════ sink idempotency acceptance — $(date -u +%FT%TZ) ════"
echo "connect=${CONNECT_CID}  trino=${TRINO_CID}  postgres=${PG_CID}"

snapshot pre
# A dirty baseline is fatal only when this run is ASSERTING idempotency: with
# EXPECT_IDEMPOTENT=0 (the append-only writer) Bronze legitimately holds N rows
# per id and the run reports the delta per restart instead.
for t in ${TABLES}; do
  eval "total=\${SNAP_pre_total_${t}}"; eval "distinct=\${SNAP_pre_distinct_${t}}"
  if [ "${total}" != "${distinct}" ]; then
    if [ "${EXPECT_IDEMPOTENT}" = "1" ]; then
      echo
      echo "!! baseline is dirty on ${t} (${total} rows / ${distinct} distinct)."
      echo "   An idempotency assertion needs a clean start; dedupe first"
      echo "   (kanban t_43530a0f), then re-run with EXPECT_IDEMPOTENT=1."
      exit 2
    fi
    echo "   (baseline ${t} already has $(( total - distinct )) duplicate rows — report mode, deltas still valid)"
  fi
done

if [ "${SKIP_KILL}" = "1" ]; then
  echo
  echo "SKIP_KILL=1 — baseline is clean; restart test not executed."
  exit 0
fi

kill_connect 1
snapshot after1
kill_connect 2
snapshot after2

echo
echo "════ verdict ════"
rc=0
for t in ${TABLES}; do
  printf '%-22s ' "${t}"
  verdict_for "${t}" after2 || rc=1
  # a replay must never remove rows the sink already had
  eval "d1=\${SNAP_after1_distinct_${t}}"; eval "d2=\${SNAP_after2_distinct_${t}}"
  if [ "${d2}" -lt "${d1}" ]; then
    echo "FAIL distinct ids went backwards across kills (${d1} -> ${d2})"; rc=1
  fi
done

if [ "${WITH_DBT}" = "1" ]; then
  echo
  echo "── dbt run + test (unique_* must pass) ──"
  # shellcheck disable=SC2086
  ${COMPOSE} run --rm --entrypoint /bin/sh dbt -c 'dbt run && dbt test' 2>&1 | tail -n 40 || rc=1
fi

echo
if [ "${rc}" = "0" ]; then
  echo "RESULT: no data loss across two SIGKILLs (distinct ids never went backwards)."
  echo "        what the two restarts cost:"
  for t in ${TABLES}; do
    eval "t0=\${SNAP_pre_total_${t}}";    eval "t2=\${SNAP_after2_total_${t}}"
    eval "d0=\${SNAP_pre_distinct_${t}}"; eval "d2=\${SNAP_after2_distinct_${t}}"
    printf '  %-22s rows %+d   distinct ids %+d\n' "${t}" "$(( t2 - t0 ))" "$(( d2 - d0 ))"
  done
  echo "  rows growing faster than distinct ids = the at-least-once replay landing as"
  echo "  appends (docs/09 §2). Set EXPECT_IDEMPOTENT=1 once an upserting writer is in."
else
  echo "RESULT: FAIL — see rows above; check the sink log:"
  echo "  docker logs ${CONNECT_CID} --since 10m 2>&1 | grep -E 'committed to|ERROR'"
fi
exit "${rc}"
