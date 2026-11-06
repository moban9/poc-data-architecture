-- =============================================================================
-- Card pack 01 — PORTFOLIO HEALTH
-- Dashboard: LMS POC — Business Performance   ·   Owner: Prism (BI)
-- Source of truth: lakehouse.gold.loan_portfolio_summary
--                   (dbt models/gold/loan_portfolio_summary.sql)
--
-- GRAIN: one row per (loan_status, loan_type, currency) — currency was added to
-- the grain by Keystone (t_51346c5a), so the mart is finer than the cards need.
--
-- MONEY UNITS — READ BEFORE EDITING A MONEY CARD:
--   total_principal / outstanding_balance / avg_amount are NOMINAL PER CURRENCY.
--   The book spans USD/EUR/GBP/JPY/CAD/AUD with NO FX conversion (deliberate:
--   option (a), see the model header). SUM-ing a money column across currencies
--   produces a mixed-currency nominal figure, which is NOT a real total.
--   => every money card below is sliced by `currency` (P2, P4, P6, P8, P9, P10).
--   => counts (P3, P5, P7) are currency-agnostic; those total safely.
--   There is intentionally no single cross-currency "headline" money number.
--
-- Every card below is a real query over the gold mart. No literals, no stubs.
-- Metric definitions: ../metric_definitions.md
--
-- Card header grammar (parsed by provision_metabase.py):
--   -- === card: NAME | display: TYPE | size: WxH | x: DIM_COL | y: METRIC[,METRIC] | fmt: COL=percent,COL=currency ===
-- =============================================================================


-- === card: Portfolio · Data as of | display: scalar | size: 6x3 ===
-- AS-OF DEFINITION: the gold marts are point-in-time builds; "now" for the
-- dataset is the latest loan_event timestamp (same value the snapshot models use).
SELECT
    CAST(MAX(occurred_at) AS date) AS as_of_date
FROM lakehouse.silver.loan_event;


-- === card: Portfolio · Loans in book | display: scalar | size: 6x3 ===
-- DEFINITION: count of clean (Silver-passing) loans, all statuses.
-- Counts are currency-agnostic, so this is a real total (unlike the money cards).
SELECT
    SUM(loan_count) AS loan_count
FROM lakehouse.gold.loan_portfolio_summary;


-- === card: Portfolio · Outstanding balance by currency | display: bar | size: 12x5 | x: currency | y: outstanding_balance | fmt: outstanding_balance=currency ===
-- DEFINITION: principal - payments received, floored at 0 per loan, summed per currency.
-- One bar per ISO-4217 currency: each bar is a real amount in its own unit.
-- Replaces the old single scalar, which summed 6 currencies into a meaningless total.
SELECT
    currency,
    ROUND(SUM(outstanding_balance), 2) AS outstanding_balance
FROM lakehouse.gold.loan_portfolio_summary
GROUP BY 1
ORDER BY 2 DESC;


-- === card: Portfolio · Principal originated by currency | display: bar | size: 12x5 | x: currency | y: total_principal | fmt: total_principal=currency ===
-- DEFINITION: gross principal written (not net of repayments), per currency.
SELECT
    currency,
    ROUND(SUM(total_principal), 2) AS total_principal
FROM lakehouse.gold.loan_portfolio_summary
GROUP BY 1
ORDER BY 2 DESC;


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


-- === card: Portfolio · Outstanding by status | display: table | size: 12x6 | fmt: outstanding_balance=currency ===
-- DEFINITION: money still owed per lifecycle status, split by currency so every
-- row carries its own unit (a status total alone would still mix 6 currencies).
SELECT
    loan_status,
    currency,
    SUM(loan_count)                    AS loan_count,
    ROUND(SUM(outstanding_balance), 2) AS outstanding_balance
FROM lakehouse.gold.loan_portfolio_summary
GROUP BY 1, 2
ORDER BY 4 DESC;


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


-- === card: Portfolio · Avg loan size by tier | display: table | size: 12x6 | fmt: avg_loan_size=currency ===
-- DEFINITION: total_principal / loan_count within the tier AND currency
-- (not the mean of means; not an average across currencies, which would be nominal nonsense).
SELECT
    loan_type,
    currency,
    SUM(loan_count)                                                  AS loan_count,
    ROUND(SUM(total_principal) / NULLIF(SUM(loan_count), 0), 2)       AS avg_loan_size
FROM lakehouse.gold.loan_portfolio_summary
GROUP BY 1, 2
ORDER BY CASE loan_type
             WHEN 'micro' THEN 1
             WHEN 'small' THEN 2
             WHEN 'medium' THEN 3
             ELSE 4
         END,
         4 DESC;


-- === card: Portfolio · Status × tier detail | display: table | size: 24x6 | fmt: total_principal=currency,outstanding_balance=currency,avg_loan_size=currency ===
-- The full mart at its native grain (one row per status × tier × currency).
SELECT
    loan_status,
    loan_type,
    currency,
    SUM(loan_count)                                                  AS loan_count,
    ROUND(SUM(total_principal), 2)                                   AS total_principal,
    ROUND(SUM(outstanding_balance), 2)                               AS outstanding_balance,
    ROUND(SUM(total_principal) / NULLIF(SUM(loan_count), 0), 2)       AS avg_loan_size
FROM lakehouse.gold.loan_portfolio_summary
GROUP BY 1, 2, 3
ORDER BY 1, CASE loan_type
                WHEN 'micro' THEN 1
                WHEN 'small' THEN 2
                WHEN 'medium' THEN 3
                ELSE 4
            END,
         3;


-- === card: Portfolio · Book by currency | display: table | size: 12x5 | fmt: total_principal=currency,outstanding_balance=currency,avg_loan_size=currency,share_of_principal=percent ===
-- SOURCE: lakehouse.gold.loan_portfolio_summary (gold) — previously read silver.loan
-- because gold had no currency dimension. It does now (Keystone t_51346c5a).
-- Why this card exists: the book is 6 currencies with no FX; this is the panel that
-- makes the split explicit and gives the per-currency share of the nominal book.
SELECT
    currency,
    SUM(loan_count)                                                 AS loan_count,
    ROUND(SUM(total_principal), 2)                                  AS total_principal,
    ROUND(SUM(outstanding_balance), 2)                              AS outstanding_balance,
    ROUND(SUM(total_principal) / NULLIF(SUM(loan_count), 0), 2)      AS avg_loan_size,
    ROUND(SUM(total_principal) / NULLIF(SUM(SUM(total_principal)) OVER (), 0), 4) AS share_of_principal
FROM lakehouse.gold.loan_portfolio_summary
GROUP BY 1
ORDER BY 3 DESC;
