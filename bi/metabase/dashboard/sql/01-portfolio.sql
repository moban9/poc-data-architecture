-- =============================================================================
-- Card pack 01 — PORTFOLIO HEALTH
-- Dashboard: LMS POC — Business Performance (Gold)   ·   Owner: Prism (BI)
-- Source of truth: lakehouse.gold.loan_portfolio_summary
--                   (dbt models/gold/loan_portfolio_summary.sql)
-- Extra card:      lakehouse.silver.loan  (currency exposure — NOT in gold yet)
--
-- Every card below is a real query over the gold mart. No literals, no stubs.
-- Metric definitions: ../metric_definitions.md
--
-- Card header grammar (parsed by provision_metabase.py):
--   -- === card: NAME | display: TYPE | size: WxH | x: DIM_COL | y: METRIC[,METRIC] | fmt: COL=percent,COL=currency ===
-- =============================================================================


-- === card: Portfolio · Data as of | display: scalar | size: 6x3 ===
-- AS-OF DEFINITION: the gold marts are point-in-time builds; "now" for the
-- dataset is the latest loan_event timestamp (see loan_delinquency.sql note).
SELECT
    CAST(MAX(occurred_at) AS date) AS as_of_date
FROM lakehouse.silver.loan_event;


-- === card: Portfolio · Outstanding balance | display: scalar | size: 6x3 | fmt: outstanding_balance=currency ===
-- DEFINITION: principal - payments received, floored at 0, summed over the book.
-- Units: nominal amount (see the FX / mixed-currency caveat in metric_definitions.md).
SELECT
    ROUND(SUM(outstanding_balance), 2) AS outstanding_balance
FROM lakehouse.gold.loan_portfolio_summary;


-- === card: Portfolio · Loans in book | display: scalar | size: 6x3 ===
-- DEFINITION: count of clean (Silver-passing) loans, all statuses.
SELECT
    SUM(loan_count) AS loan_count
FROM lakehouse.gold.loan_portfolio_summary;


-- === card: Portfolio · Principal originated | display: scalar | size: 6x3 | fmt: total_principal=currency ===
-- DEFINITION: sum of loan principal across the book (not net of repayments).
SELECT
    ROUND(SUM(total_principal), 2) AS total_principal
FROM lakehouse.gold.loan_portfolio_summary;


-- === card: Portfolio · Loans by status | display: bar | size: 12x5 | x: loan_status | y: loan_count ===
-- DEFINITION: loan_status is DERIVED from the event lifecycle
--   originated = origination event, no disbursement
--   disbursed  = funded, no payment received
--   repaying   = funded and >= 1 payment received
SELECT
    loan_status,
    SUM(loan_count) AS loan_count
FROM lakehouse.gold.loan_portfolio_summary
GROUP BY 1
ORDER BY 2 DESC;


-- === card: Portfolio · Outstanding by status | display: bar | size: 12x5 | x: loan_status | y: outstanding_balance | fmt: outstanding_balance=currency ===
SELECT
    loan_status,
    ROUND(SUM(outstanding_balance), 2) AS outstanding_balance
FROM lakehouse.gold.loan_portfolio_summary
GROUP BY 1
ORDER BY 2 DESC;


-- === card: Portfolio · Loans by tier | display: bar | size: 12x5 | x: loan_type | y: loan_count ===
-- DEFINITION: loan_type is a DERIVED principal-size tier (no product field in source):
--   micro < 25,000 <= small < 50,000 <= medium < 75,000 <= large
SELECT
    loan_type,
    SUM(loan_count) AS loan_count
FROM lakehouse.gold.loan_portfolio_summary
GROUP BY 1
ORDER BY CASE loan_type
             WHEN 'micro' THEN 1
             WHEN 'small' THEN 2
             WHEN 'medium' THEN 3
             ELSE 4
         END;


-- === card: Portfolio · Avg loan size by tier | display: bar | size: 12x5 | x: loan_type | y: avg_loan_size | fmt: avg_loan_size=currency ===
-- DEFINITION: total_principal / loan_count within the tier (not the mean of means).
SELECT
    loan_type,
    ROUND(SUM(total_principal) / NULLIF(SUM(loan_count), 0), 2) AS avg_loan_size
FROM lakehouse.gold.loan_portfolio_summary
GROUP BY 1
ORDER BY CASE loan_type
             WHEN 'micro' THEN 1
             WHEN 'small' THEN 2
             WHEN 'medium' THEN 3
             ELSE 4
         END;


-- === card: Portfolio · Status × tier detail | display: table | size: 24x6 | fmt: total_principal=currency,outstanding_balance=currency,avg_loan_size=currency ===
-- The full mart at its native grain (one row per status × tier).
SELECT
    loan_status,
    loan_type,
    SUM(loan_count)                                                  AS loan_count,
    ROUND(SUM(total_principal), 2)                                   AS total_principal,
    ROUND(SUM(outstanding_balance), 2)                               AS outstanding_balance,
    ROUND(SUM(total_principal) / NULLIF(SUM(loan_count), 0), 2)       AS avg_loan_size
FROM lakehouse.gold.loan_portfolio_summary
GROUP BY 1, 2
ORDER BY 1, CASE loan_type
                WHEN 'micro' THEN 1
                WHEN 'small' THEN 2
                WHEN 'medium' THEN 3
                ELSE 4
            END;


-- === card: Portfolio · Book by currency | display: table | size: 12x5 | fmt: principal=currency ===
-- SOURCE: lakehouse.silver.loan (gold has NO currency dimension — see README "Known gaps").
-- Why this card exists: every gold monetary KPI sums across 6 currencies with no FX
-- conversion. This panel makes the mixed-currency exposure visible instead of hidden.
SELECT
    currency,
    COUNT(*)              AS loan_count,
    ROUND(SUM(amount), 2) AS principal
FROM lakehouse.silver.loan
GROUP BY 1
ORDER BY 3 DESC;
