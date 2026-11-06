-- =============================================================================
-- Card pack 04 — DATA QUALITY (quarantine)
-- Dashboard: LMS POC — Data Quality   ·   Owner: Prism (BI)
-- Source of truth: lakehouse.quarantine_lms.quarantine_lms
--                   (dbt models/quarantine.sql, 11-column append-only DQ log;
--                    filled by models/silver/quarantine/* + macros/quarantine_failed_tests.sql)
--
-- WHY THIS PANEL EXISTS: bad rows never reach a KPI — they land here. A rising
-- count is the visible cost of dirty source data.
--
-- WHY IT IS A SEPARATE DASHBOARD (not a panel on the business board): quarantine
-- counts are pipeline diagnostics, not business performance. Sitting next to the
-- portfolio numbers they invited the reading "N bad rows = N bad loans", and they
-- pushed the business headline tiles down the page. Randy asked for the split;
-- the business board is now business-only, this board is the DQ/ops read.
--
-- GRAIN: append-only, one row per offending source row per dbt run. Counts are
-- therefore "quarantined row-events", not current bad-row inventory. The two
-- panels that answer different questions are labelled accordingly.
-- =============================================================================


-- === card: DQ · Quarantined rows (all runs) | display: scalar | size: 6x3 ===
-- DEFINITION: total row-events ever written to the quarantine log (all dbt runs, all rules).
SELECT
    COUNT(*) AS quarantined_rows
FROM lakehouse.quarantine_lms.quarantine_lms;


-- === card: DQ · Distinct rules triggered | display: scalar | size: 6x3 ===
-- DEFINITION: how many distinct DQ rules have fired at least once in the log.
SELECT
    COUNT(DISTINCT "rule") AS distinct_rules
FROM lakehouse.quarantine_lms.quarantine_lms;


-- === card: DQ · Latest quarantine timestamp | display: scalar | size: 6x3 ===
-- DEFINITION: newest quarantined_at in the log — i.e. the last time DQ isolated a row.
-- If this is stale relative to the last dbt run, the DQ hooks did not fire.
SELECT
    MAX(quarantined_at) AS last_quarantined_at
FROM lakehouse.quarantine_lms.quarantine_lms;


-- === card: DQ · Runs in log | display: scalar | size: 6x3 ===
-- DEFINITION: number of distinct dbt run_ids that wrote quarantine rows.
SELECT
    COUNT(DISTINCT run_id) AS runs_with_quarantine
FROM lakehouse.quarantine_lms.quarantine_lms;


-- === card: DQ · Quarantined rows by rule | display: bar | size: 24x6 | x: rule | y: quarantined_rows ===
-- DEFINITION: row-events grouped by the rule id that rejected them, all runs.
-- The rule id is stored by dbt (e.g. positive_value, relationships__borrower_id__dim_borrower).
SELECT
    "rule",
    "rule_type",
    COUNT(*) AS quarantined_rows
FROM lakehouse.quarantine_lms.quarantine_lms
GROUP BY 1, 2
ORDER BY 3 DESC;


-- === card: DQ · Quarantine by layer and target table | display: table | size: 12x5 ===
-- DEFINITION: where the rejected rows came from (bronze|silver|gold × model name).
SELECT
    "layer",
    target_table,
    COUNT(*)              AS quarantined_rows,
    MAX(quarantined_at)   AS last_quarantined_at
FROM lakehouse.quarantine_lms.quarantine_lms
GROUP BY 1, 2
ORDER BY 3 DESC;


-- === card: DQ · Quarantine by run (latest 20) | display: table | size: 12x6 ===
-- DEFINITION: per dbt invocation — how many rows were isolated and by which path
-- ('batch' = dbt run, 'cdc' = Debezium stream).
SELECT
    run_id,
    "source",
    COUNT(*)               AS quarantined_rows,
    COUNT(DISTINCT "rule") AS rules_tripped,
    MIN(quarantined_at)    AS first_at,
    MAX(quarantined_at)    AS last_at
FROM lakehouse.quarantine_lms.quarantine_lms
GROUP BY 1, 2
ORDER BY last_at DESC
LIMIT 20;


-- === card: DQ · Rules tripped in the latest run | display: table | size: 24x5 ===
-- DEFINITION: the current-run picture — only rows from the most recent dbt run_id.
-- This is the panel to watch during a "dirty" scenario; it resets each run.
SELECT
    "rule",
    "rule_type",
    target_table,
    COUNT(*) AS quarantined_rows
FROM lakehouse.quarantine_lms.quarantine_lms
WHERE run_id = (
    SELECT run_id
    FROM lakehouse.quarantine_lms.quarantine_lms
    WHERE run_id IS NOT NULL
    ORDER BY quarantined_at DESC
    LIMIT 1
)
GROUP BY 1, 2, 3
ORDER BY 4 DESC;
