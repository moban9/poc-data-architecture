# CDC delivery semantics — at-least-once source, append-only sink

Status 2026-11-05 (final): **decision recorded — Option A (dedupe on read)**,
approved by the CEO. Shipped: reconcile-only connector registration (§4.1),
`snapshot.mode=no_data` for the Debezium source (§4.2), and the Silver dedupe
(§6.1). Measured: the 2.07x Bronze inflation was **source re-emission from
repeated aborted snapshots**, not sink replay — for a healthy connector with
committed offsets, a `SIGKILL` restart costs the uncommitted window only (§7).

Owner: Keel (infra) · affected services: `connect`, `register-connectors` ·
downstream: dbt/silver, portfolio + payments KPIs.

## 1. What went wrong (measured, 2026-11-05, `lms-poc-vm`)

Final Bronze state after the backlog drained (17:20 UTC), against source
`lms-postgres`:

| table | bronze rows | distinct `id` | source rows | rows per id |
|---|---|---|---|---|
| `bronze.loan` | 354,360 | 354,360 | 354,360 | 1.0 (deduped by CEO earlier) |
| `bronze.loan_event` | 744,605 | 744,605 | 744,605 | 1.0 (deduped by CEO earlier) |
| `bronze.repayment_schedule` | **14,347,023** | **6,908,334** | 6,908,334 | **2.08** (never deduped) |

Downstream before the fix: `dbt test` failures `unique_repayment_schedule_id`
(177,311 at 16:40) and `relationships_loan_event_loan_id` (35,073); portfolio and
payments KPIs ~2.7x inflated until the duplicates were removed by hand.

## 2. Mechanism — measured, and it is not what it looked like

Bronze is append-only (§3), so *something* upstream must be delivering each row
more than once. Two candidates: the sink re-appending what it consumes, or the
source emitting the same rows more than once. **The data says it was the source.**

Evidence from `bronze.repayment_schedule` (Trino, 2026-11-05 17:26 UTC):

| measurement | value | what it rules out |
|---|---|---|
| `count(*)` | 14,347,023 | — |
| `count(DISTINCT "_cdc"."offset")` | **14,347,023** | **sink replay.** Every Bronze row carries a *distinct* Kafka offset, so no record was appended twice. The sink wrote exactly one row per topic record. |
| Kafka topic `lms.public.repayment_schedule` LOG-END-OFFSET | 14,347,023 | identical to Bronze rows — 1:1 consumption, zero duplicates from the sink. |
| copies per `id` | min 1, **max 46**; 6.9M ids | a single re-snapshot would give exactly 2 copies of every row. |
| arrivals by hour of `"_cdc"."ts"` | 15:00 → 8,324,868 rows for **1,690,955** distinct ids (4.9x); 16:00 → 2,912,469 rows / 2,571,302 ids | the multiplication is concentrated in the crash-loop window, and it is *partial* — a fingerprint of restarts, not of one clean snapshot. |

The shape (some ids 46 copies, most 1) is the signature of **repeated aborted
snapshots**: `snapshot.mode=initial` means "snapshot when there are no stored
offsets". The connector was crash-looping (Connect OOM, Polaris OOM); each
restart found no stored offsets — because the snapshot never finished — and
re-emitted the table from the first row again, until the crash-loop fix let one
snapshot complete.

So the multiplying factors are:

1. **The sink is at-least-once, inherently.** Kafka Connect commits consumer
   offsets *after* the Iceberg commit. A crash in between re-delivers the records
   consumed since the last offset commit. On this table it happened to cost zero
   rows (distinct offsets == rows), because the sink never died inside a commit
   window — but the contract allows it, and the restart harness in §7 measures it.
2. **The writer appends** (§3), so any re-delivery becomes a second row.
3. **`snapshot.mode=initial` re-emits on every offset-less start** — the
   amplifier that produced 2.08x here.
4. **`register-connectors` re-`PUT` every config on every `docker compose up -d`
   and restarted the connector tasks**, making point 3 self-inflicted on every
   deploy. Fixed in §4.1.

## 3. The blocker — upsert mode does not exist in the pinned connector

The obvious fix (`iceberg.tables.upsert-mode-enabled=true` +
`iceberg.tables.default-id-columns=id`) **cannot work on this stack**, and adding
those properties would have been dead configuration that silently does nothing:

- `scripts/fetch-iceberg-jars.sh` pins `org.apache.iceberg:iceberg-kafka-connect:1.9.2`.
- The **Apache** sink is append-only. `RecordUtils.createTableWriter` builds an
  `UnpartitionedWriter` / `PartitionedAppendWriter`; `IcebergWriter.write` appends
  every non-null value and ignores tombstones. `id-columns` sets
  `identifierFieldIds` for an equality-delete writer factory that no writer ever
  uses. The `RowDelta` branch in `Coordinator` is unreachable from this sink.
- `iceberg.tables.upsert-mode-enabled` and `iceberg.tables.cdc-field` are
  **Tabular-era** keys. They are absent from `IcebergSinkConfig.newConfigDef()` on
  1.10.2 and 1.12.0 (released 2026-09-29), and Kafka Connect ignores unknown
  connector properties silently — which is why the failure looks like "config
  applied, duplicates continue".
- Upstream status: requests/dupes in apache/iceberg #10842, #13986, #15046,
  #17542; PR #14797 (delta writer) and PR #17899 (upsert option) were both
  closed without merging. Verified against the 1.12.0 source, not against blog
  posts — most blog posts still show the Tabular keys.

**Consequence:** "make the sink idempotent" cannot be satisfied by configuration
on any current Apache release. It needs a different writer, or deduplication
after the fact.

## 4. What shipped

### 4.1 Registration is a reconcile, not a re-PUT

`compose/connectors/register-connectors.sh`:

1. render the template (`envsubst`);
2. `GET /connectors/<name>/config`;
3. absent → `PUT` (create); identical → **skip**, no request, no task restart;
4. different → `PUT`, logging which keys changed/removed.

A non-200 other than 404 aborts the run — an auth failure must never be mistaken
for "not registered" (that would turn a reconcile into a blind re-PUT).

Verified on the VM 2026-11-05 17:15 UTC, two consecutive runs:

```
RUN 1  → debezium-postgres: config differs — updating
          changed: snapshot.mode
       = iceberg-sink: config unchanged — skipping PUT (no task restart)
RUN 2  = debezium-postgres: config unchanged — skipping PUT (no task restart)
       = iceberg-sink: config unchanged — skipping PUT (no task restart)
```

Run 2 is the `docker compose up` case: no PUT, no task restart, no replay.

| var | default | use |
|---|---|---|
| `FORCE_REGISTER` | `0` | `1` = old always-PUT behaviour (forces a task restart) |
| `DRY_RUN` | `0` | `1` = print the plan, change nothing |
| `WAIT_FOR_RUNNING` | `1` | wait for connector + tasks `RUNNING` after a create/update |
| `IGNORE_EXTRA_KEYS` | `name` | worker-reported keys that must not count as a diff |
| `SNAPSHOT_MODE` | `no_data` | Debezium `snapshot.mode` (§4.2) |

### 4.2 `snapshot.mode=no_data` — a recreate never re-emits history

```jsonc
"snapshot.mode": "${SNAPSHOT_MODE}"   // default no_data
```

With `no_data`, a connector that is recreated without offsets resumes from the
WAL and emits **no** data rows. That removes the §2.3 amplifier entirely.

Measured on the VM: applying it (17:15 UTC) re-PUT only the source connector, and
every topic end-offset stayed byte-identical afterwards —

| topic | end offset before | after |
|---|---|---|
| `lms.public.loan` | 960,831 | 960,831 |
| `lms.public.loan_event` | 2,015,918 | 2,015,918 |
| `lms.public.repayment_schedule` | 14,347,023 | 14,347,023 |
| `lms.public.borrower` | 8 | 8 |

The sink task was **not** restarted by the reconcile (same consumer client-id
`connector-consumer-iceberg-sink-0-135c2df6…` before and after).

Trade-off, stated plainly: a **brand-new** environment (empty topics, no offsets)
now bootstraps with no data. Bootstrap it explicitly with
`SNAPSHOT_MODE=initial ./register-connectors.sh debezium-postgres`, or run
`resnapshot.sh` — which is the only entry point that opts into `initial`, and
which now says so in its output.

## 5. Decision — Option A, approved

| # | option | verdict |
|---|---|---|
| **A** | **Dedupe on read in Silver** (`latest_cdc_row`), Bronze documented as a changelog, periodic Bronze reconcile | **APPROVED** (CEO, 2026-11-05). No new spend, no new always-on JVM. |
| B | Flink / Spark Structured Streaming upsert writer | **NOT approved.** Native upsert, but a new always-on JVM (≥2–4 GB) on the VM implies a resize = spend. Revisit only if Bronze itself must be current-state. |
| C | Tabular-era connector (`io.tabular.iceberg:iceberg-kafka-connect-runtime:0.6.x`) — the only build where the requested keys work as written | Rejected: archived/unmaintained, unverified against Iceberg 1.12 + Polaris REST, equality deletes need compaction anyway. |
| D | Build the closed PR #14797 patch | Rejected: we would own the patch forever, upstream rejected it on performance grounds. |

## 6. Contract for downstream

### 6.1 Silver dedupes; Bronze stays a changelog

- **`bronze.*` is a changelog**, not a current-state table: N rows per `id` are
  legitimate, one per delivery. Do not assume uniqueness, and do not compare
  `count(*)` to the source.
- **Latest wins** by `"_cdc"."ts"` (Debezium `ts_ms`), ties broken by
  `"_cdc"."offset"`. Do **not** dedupe on offset alone: an at-least-once replay
  writes the *same* Kafka offset twice, so offset is not a unique row identity.
- **Silver** collapses the changelog at its boundary — every Bronze read goes
  through `latest_cdc_row()` (`dbt/macros/latest_cdc_row.sql`), which keeps
  `row_number() over (partition by id order by "_cdc"."ts" desc, "_cdc"."offset"
  desc) = 1`. Applied in `stg_loan`, `stg_repayment_schedule`, `loan_event`,
  `dim_borrower`.
- **Performance note (learned the hard way):** pass `latest_cdc_row()` an
  explicit narrow column list, never `select *`. The window's top-n operator
  holds one row per `id` in memory; projecting the wide `_cdc` STRUCT pushes the
  6.9M-id `repayment_schedule` dedupe to >900 MB and over Trino's per-node query
  limit (921.6 MB = 0.3 × 3 GB heap). Narrow projection: 6,908,334 rows in 21 s.
  Also run the dbt build with `--threads 1` on this single-node Trino — concurrent
  model queries share that one per-node budget.
- **Deletes are not represented.** The append writer drops tombstone records, so
  a DELETEd source row keeps its last value in Bronze *and* in Silver.
- **Ordering** is per Kafka partition = per `id`; cross-table ordering (`loan` vs
  `loan_event`) is *not* guaranteed.
- Any model asserting `unique` on a Bronze-derived key must dedupe first,
  otherwise it is testing Kafka, not the data.

### 6.2 Periodic Bronze reconcile (owned by the data team)

Bronze keeps growing until someone compacts it: every row above the source count
is a historical version. The reconcile is a rename-based, re-runnable dedupe
(`row_number() over (partition by id order by "_cdc"."ts" desc) = 1`) that keeps
the pre-dedupe table as `*_pre_dedupe_<date>` — Polaris rejects table removal, so
rename, don't drop. Tracked as kanban `t_43530a0f` (cask) for
`bronze.repayment_schedule`.

## 7. Measuring the replay (acceptance harness)

`./connectors/verify-idempotency.sh` on the VM (from `/home/ubuntu/poc/compose`):

- `SIGKILL`s `connect` twice, waits for `iceberg-sink` `RUNNING` + two commit
  cycles, and compares `count(*)` / `count(DISTINCT id)` against the live source
  after each kill;
- prints the sink consumer lag before each kill, so the replayed window is
  visible in the log;
- a dirty baseline is fatal (`exit 2`) **only** with `EXPECT_IDEMPOTENT=1`; in
  report mode it prints the existing duplicate count and continues, because
  Bronze is a changelog;
- `EXPECT_IDEMPOTENT=1` turns any duplicate row into a hard failure — use it once
  an upserting writer exists;
- `SKIP_KILL=1` = report only; `WITH_DBT=1` = also run `dbt run && dbt test`.

Results: see §9.

## 8. Rollback

- **Registration**: `FORCE_REGISTER=1` restores the old always-PUT behaviour for
  one run. The script never deletes or edits a connector config it did not
  render.
- **Snapshot mode**: `SNAPSHOT_MODE=initial ./register-connectors.sh
  debezium-postgres` + `FORCE_REGISTER=1` if a deliberate re-snapshot is needed;
  then reconcile back to `no_data`.
- **Silver dedupe**: revert the four models + `dbt/macros/latest_cdc_row.sql` and
  `dbt run --select silver gold`. Bronze is untouched by this change, so nothing
  is lost by reverting.
- **Data**: nothing in this change set deletes or rewrites Bronze rows.

## 9. Verification log (2026-11-05, `lms-poc-vm`, all commands run on the VM)

### 9.1 Registration is a no-op when nothing changed — §4.1

Two consecutive `./register-connectors.sh` runs at 17:15 UTC (quoted in §4.1):
run 1 PUT only `debezium-postgres` (`changed: snapshot.mode`), run 2 was two
`skipping PUT (no task restart)` lines. The sink's consumer client-id was
`connector-consumer-iceberg-sink-0-135c2df6-…` before and after — the sink task
never restarted, which is the property that used to cost duplicate rows on every
deploy.

### 9.2 `snapshot.mode=no_data` survives a worker kill — §4.2 / acceptance 3

`verify-idempotency.sh` SIGKILLs the whole `connect` worker twice, which restarts
the source connector from scratch. Topic end-offsets before the first kill and
after the second kill are **identical**:

| topic | before | after 2×SIGKILL |
|---|---|---|
| `lms.public.loan` | 960,831 | 960,831 |
| `lms.public.loan_event` | 2,015,918 | 2,015,918 |
| `lms.public.repayment_schedule` | 14,347,023 | 14,347,023 |
| `lms.public.borrower` | 8 | 8 |

Source row counts static (354,360 / 744,605 / 6,908,334 / 4) throughout. With
`snapshot.mode=initial` this test would have re-emitted 6.9M rows per restart.

### 9.3 Silver dedupe — acceptance 1

`dbt run --select silver gold --threads 1`: `PASS=16 ERROR=0`.

| model | rows | note |
|---|---|---|
| `silver.stg_repayment_schedule` | **6,908,334** | 164s; was 12.7M mid-drain, dedupe window over the 14.3M-row changelog |
| `silver.repayment_schedule` | 6,580,511 | after the DQ filter + inner join to `silver.loan` |
| `silver.loan` | 337,590 | 354,360 minus DQ failures |
| `silver.loan_event` | 705,335 | 744,605 − 4,197 NULL `loan_id` − 35,073 orphan `loan_id` |

`dbt test --threads 1`: `PASS=64`, 5 failures, all `dirty_data` seed tests —
the intentionally bad seed that the DQ gate exists to catch. Every
`unique_*` and `relationships_*` test passes, including the three that were
failing on this card:

```
PASS unique_repayment_schedule_id
PASS unique_loan_event_id
PASS unique_loan_id
PASS relationships_loan_event_loan_id__id__ref_loan_
PASS relationships_repayment_schedule_loan_id__id__ref_loan_
PASS relationships_loan_borrower_id__id__ref_dim_borrower_
```

The `relationships_loan_event_loan_id` failure was **not** a duplication
artefact: 4,197 events have a NULL `loan_id` and 35,073 reference loans that the
loan DQ rules removed from `silver.loan`. `silver/loan_event.sql` now filters
both (same inner-join pattern as `silver/repayment_schedule.sql`); the excluded
rows are appended to `quarantine_lms` by the on-run-end hook. Gold
`loan_event_daily` therefore drops events for loans that failed DQ — that is the
intended DQ-gate behaviour, not a regression.

### 9.4 Kill test — acceptance 2

`EXPECT_IDEMPOTENT=0 ./connectors/verify-idempotency.sh`, 17:49–17:56 UTC:

```
loan                   PASS 354360 rows == 354360 distinct ids
loan_event             PASS 744605 rows == 744605 distinct ids
borrower               PASS 4 rows == 4 distinct ids
repayment_schedule     REPLAY COST: +7,438,689 duplicate rows (pre-existing baseline)

what the two restarts cost:
  loan                   rows +0   distinct ids +0
  loan_event             rows +0   distinct ids +0
  borrower               rows +0   distinct ids +0
  repayment_schedule     rows +0   distinct ids +0
```

Two hard kills cost **zero** rows on a caught-up pipeline: with the source idle
and the sink at lag 0, there is no uncommitted window to replay. That is the
honest bound — the duplicate exposure of a crash is whatever the sink consumed
since its last 10s offset commit, not the table. It also confirms §2 from the
other direction: restarts were not what inflated `repayment_schedule`.

The 7,438,689 pre-existing duplicate rows in `bronze.repayment_schedule` are
left for the Bronze reconcile (`t_43530a0f`) — this change does not rewrite
Bronze.

### 9.5 Trino memory (infra prerequisite for 9.3)

The dedupe failed twice with `EXCEEDED_LOCAL_MEMORY_LIMIT: per-node memory limit
of 921.60MB [Top Consumers: {TopNRankingOperator=776.72MB, LocalExchange=123.68MB}]`
— 921.6MB is Trino's default `0.3 × Xmx` on the 3GB heap. Fixed by mounting
`compose/trino/config.properties` with `query.max-memory-per-node=1536MB`
(`query.max-total-memory-per-node` is defunct on Trino 484 — it makes the server
refuse to start). No VM resize, no extra spend; the container still has 4GB.

### 9.6 Operational note — Dagster schedule unwedged (kanban t_1184e3c6)

`dbt_pipeline_schedule` (`*/2 * * * *`) had produced **290 queued runs** (438
already auto-cancelled) because a full silver/gold rebuild takes far longer than
2 minutes on this dataset; two ran concurrently at all times and the queue grew
without bound. Root cause, measured: the `*/2` cadence + `max_concurrent_runs: 2`
starved the daemon, and its in-process code server — which has a **hard-coded
20s heartbeat TTL** (`dagster._daemon.controller.DAEMON_GRPC_SERVER_HEARTBEAT_TTL`,
not configurable) — could not answer the 1s heartbeat pings under the old
`mem_limit=1g`/`cpus=0.5`, so it shut down ~every 65s. Two runs wedged in
`STARTED`/`STARTING` and held both concurrency slots for ~10h; nothing drained.

Resolved (all reversible, no data touched):

- cadence `*/2` → `*/15` (`DAGSTER_DBT_CRON` default in compose +
  `definitions.py` + `.env.example`), with `tag_concurrency_limits` dbt=1 kept;
- webserver `mem_limit` 1g→2g and `cpus` 0.5→1.0; daemon 768m→1g and 0.5→1.0
  (host has ~19GB free — the heartbeat watchdog is resource-starved, not OOM);
- dbt scoped: `dbt run --select silver gold --threads 1` (single-node Trino
  shares one 1536MB per-node budget; §6.1, §9.5);
- wedged runs cleared (non-terminal runs marked `CANCELED` in the `runs` table —
  metadata only, they never executed dbt), schedule re-enabled and verified to
  produce exactly one SUCCESS run per tick.

`terminateRun` (this build has no `cancelRun`) returns `TerminateRunFailure` for
runs already stuck in `STARTING`/`CANCELING`/`NOT_STARTED` — those must be cleared
by updating `runs.status` directly in `dagster-postgres`, then restarting the
daemon. Do not resume the schedule at `*/2` cadence.

