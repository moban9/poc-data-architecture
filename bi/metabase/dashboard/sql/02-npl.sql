-- =============================================================================
-- Card pack 02 — NPL / DELINQUENCY
-- Dashboard: LMS POC — Business Performance (Gold)   ·   Owner: Prism (BI)
-- Source of truth: lakehouse.gold.loan_delinquency
--                   (dbt models/gold/loan_delinquency.sql)
--
-- GRANULARITY WARNING (read before changing anything): loan_delinquency is a
-- POINT-IN-TIME SNAPSHOT — one row per bucket, no date dimension. The "NPL
-- trend over time" panel required by the directive is therefore NOT available
-- from this mart. It is not faked here: it is tracked as a pipeline gap and
-- raised to Keystone (architect) — see README "Known gaps".
-- =============================================================================


-- === card: NPL · NPL rate (90+ / outstanding) | display: scalar | size: 6x3 | fmt: npl_rate=percent ===
-- DEFINITION: npl_rate = outstanding of the 90+ bucket / total outstanding.
-- Carried identically on every row of the mart; MAX() collapses to one value.
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
-- DEFINITION: outstanding balance sitting in the 90+ bucket (the NPL numerator).
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


-- === card: NPL · Overdue instalments by due month (proxy trend) | display: table | size: 24x6 | fmt: overdue_amount=currency,overdue_share=percent ===
-- HONEST PROXY, NOT an NPL trend. This is a real, supported time dimension:
-- for each contractual due month, how much of the scheduled amount is still
-- marked 'overdue' in the repayment schedule. It shows WHEN the book started
-- slipping; it is NOT a historical NPL-rate series (gold keeps no history).
-- Source: lakehouse.silver.repayment_schedule.
SELECT
    SUBSTR(CAST(due_date AS varchar), 1, 7)                                        AS due_month,
    COUNT(*)                                                                        AS installments,
    COUNT(*) FILTER (WHERE status = 'overdue')                                      AS overdue_installments,
    COALESCE(ROUND(SUM(principal_due + interest_due) FILTER (WHERE status = 'overdue'), 2), 0) AS overdue_amount,
    ROUND(SUM(principal_due + interest_due), 2)                                     AS scheduled_amount,
    ROUND(
        SUM(principal_due + interest_due) FILTER (WHERE status = 'overdue')
        / NULLIF(SUM(principal_due + interest_due), 0), 4)                          AS overdue_share
FROM lakehouse.silver.repayment_schedule
GROUP BY 1
ORDER BY 1;
