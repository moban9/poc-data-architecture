-- =============================================================================
-- Card pack 02 — NPL / DELINQUENCY
-- Dashboard: LMS POC — Business Performance (Gold)   ·   Owner: Prism (BI)
-- Sources:
--   lakehouse.gold.loan_delinquency           — point-in-time mart (current snapshot)
--                                               (dbt models/gold/loan_delinquency.sql)
--   lakehouse.gold.loan_delinquency_snapshot  — append-only snapshot HISTORY
--                                               (dbt models/gold/loan_delinquency_snapshot.sql)
--
-- The "NPL trend over time" gap is CLOSED: N7/N8/N9 read the snapshot history,
-- which grows one row-set per distinct dataset "now" (one `dbt run` day = one date).
-- The series renders ONLY real dates — early in the POC that is 2 points, and the
-- card must never be padded to look like a longer history.
--
-- UNITS — IMPORTANT:
--   npl_rate is a ratio (90+ outstanding / total outstanding): dimensionless and
--   meaningful across currencies, even though the underlying balances are nominal.
--   npl_loan_count / loan_count are counts: real totals.
--   outstanding_balance is a NOMINAL multi-currency sum — the snapshot grain has
--   (as_of_date, delinquency_bucket) and NO currency column (deliberate scope of
--   Keystone t_51346c5a). Any balance tile in this pack is therefore "nominal, all
--   currencies" and is labelled as such; it is not a convertible amount and must
--   not be added to a portfolio money figure.
--
-- Buckets: current (<30 DPD) · 30-59 · 60-89 · 90+ (= NPL). There is NO
-- `charge-off` bucket — the LMS source has no write-off event. Do not add one
-- until src/lms grows a write-off event.
-- =============================================================================


-- === card: NPL · NPL rate (90+ / outstanding) | display: scalar | size: 6x3 | fmt: npl_rate=percent ===
-- DEFINITION: npl_rate = outstanding of the 90+ bucket / total outstanding,
-- carried identically on every row of the point-in-time mart; MAX() collapses to one value.
-- Units: fraction 0..1 (Metabase renders as percent).
SELECT
    MAX(npl_rate) AS npl_rate
FROM lakehouse.gold.loan_delinquency;


-- === card: NPL · Loans 90+ days past due | display: scalar | size: 6x3 ===
-- DEFINITION: disbursed loans whose oldest overdue instalment is >= 90 days past the as-of date.
SELECT
    SUM(CASE WHEN delinquency_bucket = '90+' THEN loan_count ELSE 0 END) AS npl_loan_count
FROM lakehouse.gold.loan_delinquency;


-- === card: NPL · 90+ exposure | display: scalar | size: 6x3 | fmt: npl_outstanding=currency ===
-- DEFINITION: outstanding sitting in the 90+ bucket (the NPL numerator).
-- UNIT CAVEAT: nominal, all currencies — the snapshot has no currency dimension.
SELECT
    ROUND(SUM(CASE WHEN delinquency_bucket = '90+' THEN outstanding_balance ELSE 0 END), 2) AS npl_outstanding
FROM lakehouse.gold.loan_delinquency;


-- === card: NPL · Delinquency buckets | display: table | size: 24x5 | fmt: outstanding_balance=currency,share_of_book=percent,share_of_loans=percent ===
-- DEFINITION: buckets are days-past-due bands at the as-of date:
--   current (<30) · 30-59 · 60-89 · 90+ (= NPL)
-- dpd = as_of_date - oldest 'overdue' instalment due_date (real repayment_schedule,
-- not a term assumption). share_of_book / share_of_loans are computed across buckets.
SELECT
    delinquency_bucket,
    loan_count,
    ROUND(outstanding_balance, 2)                                              AS outstanding_balance,
    ROUND(outstanding_balance / NULLIF(SUM(outstanding_balance) OVER (), 0), 4) AS share_of_book,
    ROUND(CAST(loan_count AS double) / NULLIF(SUM(loan_count) OVER (), 0), 4)   AS share_of_loans
FROM lakehouse.gold.loan_delinquency
ORDER BY CASE delinquency_bucket
             WHEN 'current' THEN 1
             WHEN '30-59'   THEN 2
             WHEN '60-89'   THEN 3
             ELSE 4
         END;


-- === card: NPL · Outstanding by bucket | display: bar | size: 12x5 | x: delinquency_bucket | y: outstanding_balance | fmt: outstanding_balance=currency ===
-- Nominal, all currencies (see file header).
SELECT
    delinquency_bucket,
    ROUND(outstanding_balance, 2) AS outstanding_balance
FROM lakehouse.gold.loan_delinquency
ORDER BY CASE delinquency_bucket
             WHEN 'current' THEN 1
             WHEN '30-59'   THEN 2
             WHEN '60-89'   THEN 3
             ELSE 4
         END;


-- === card: NPL · Loans by bucket | display: bar | size: 12x5 | x: delinquency_bucket | y: loan_count ===
SELECT
    delinquency_bucket,
    loan_count
FROM lakehouse.gold.loan_delinquency
ORDER BY CASE delinquency_bucket
             WHEN 'current' THEN 1
             WHEN '30-59'   THEN 2
             WHEN '60-89'   THEN 3
             ELSE 4
         END;


-- === card: NPL · NPL rate trend (snapshot dates) | display: line | size: 12x5 | x: as_of_date | y: npl_rate | fmt: npl_rate=percent ===
-- REAL TREND (replaces the old "overdue by due month" proxy card).
-- One point per distinct dataset "now" that the snapshot has captured: npl_rate is
-- carried on every bucket row of a date, so MAX() per date gives the portfolio rate.
-- HONEST LIMIT: points exist only for dates the pipeline has actually run on
-- (2 at the time of writing: 2026-12-05, 2026-12-06). No backfill, no interpolation.
SELECT
    as_of_date,
    MAX(npl_rate) AS npl_rate
FROM lakehouse.gold.loan_delinquency_snapshot
GROUP BY 1
ORDER BY 1;


-- === card: NPL · Outstanding by bucket over snapshot dates | display: bar | size: 14x5 | x: as_of_date | y: current_lt_30,dpd_30_59,dpd_60_89,dpd_90_plus | fmt: current_lt_30=currency,dpd_30_59=currency,dpd_60_89=currency,dpd_90_plus=currency ===
-- Bucket mix per snapshot date (one series per bucket). Shows whether the move in
-- NPL rate is volume (book shrinking) or migration (balance sliding down the buckets).
-- Nominal, all currencies (see file header).
-- NOTE: aliases are safe identifiers on purpose — bare `current` is a Trino reserved word.
SELECT
    as_of_date,
    ROUND(SUM(CASE WHEN delinquency_bucket = 'current' THEN outstanding_balance ELSE 0 END), 2) AS current_lt_30,
    ROUND(SUM(CASE WHEN delinquency_bucket = '30-59'   THEN outstanding_balance ELSE 0 END), 2) AS dpd_30_59,
    ROUND(SUM(CASE WHEN delinquency_bucket = '60-89'   THEN outstanding_balance ELSE 0 END), 2) AS dpd_60_89,
    ROUND(SUM(CASE WHEN delinquency_bucket = '90+'     THEN outstanding_balance ELSE 0 END), 2) AS dpd_90_plus
FROM lakehouse.gold.loan_delinquency_snapshot
GROUP BY 1
ORDER BY 1;


-- === card: NPL · Snapshot history (bucket × date) | display: table | size: 24x6 | fmt: outstanding_balance=currency,share_of_book=percent,npl_rate=percent ===
-- The audit view behind N7/N8: the append-only snapshot at its native grain.
-- Use it to verify a point on the trend line against the rows it came from.
SELECT
    as_of_date,
    delinquency_bucket,
    loan_count,
    ROUND(outstanding_balance, 2)                                              AS outstanding_balance,
    ROUND(outstanding_balance / NULLIF(SUM(outstanding_balance) OVER (PARTITION BY as_of_date), 0), 4) AS share_of_book,
    npl_rate
FROM lakehouse.gold.loan_delinquency_snapshot
ORDER BY as_of_date,
         CASE delinquency_bucket
             WHEN 'current' THEN 1
             WHEN '30-59'   THEN 2
             WHEN '60-89'   THEN 3
             ELSE 4
         END;
