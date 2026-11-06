-- =============================================================================
-- Card pack 01 — PORTFOLIO HEALTH
-- Dashboard: LMS POC — Business Performance   ·   Owner: Prism (BI)
-- Source of truth: lakehouse.gold.loan_portfolio_summary
--                   (dbt models/gold/loan_portfolio_summary.sql)
--
-- GRAIN: one row per (loan_status, loan_type, currency). The mart is FINER than
-- these cards need. The POC book is single-currency (IDR) — Randy's call, task
-- t_d2573cb4 — so every money card below sums across the whole book with NO
-- currency dimension and prints ONE real total.
--
-- MONEY UNITS — READ BEFORE EDITING A MONEY CARD:
--   total_principal / outstanding_balance / avg_amount are nominal amounts in the
--   book's single currency (IDR). A SUM that spans more than one currency would be
--   a mixed-currency nominal figure with no FX conversion behind it — so the
--   single-currency invariant is a CARD, not a comment:
--       P10 "Portfolio · Currency codes in book (must be 1)" = COUNT(DISTINCT currency)
--   If P10 ever reads > 1, then P2/P4/P6/P8/P9 are multi-currency sums and must be
--   sliced by currency again (or filtered to one code) before any number is quoted.
--   Do not drop P10 while the mart still carries a currency column.
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


-- === card: Portfolio · Outstanding balance | display: scalar | size: 6x3 | fmt: outstanding_balance=currency ===
-- DEFINITION (P2): principal - payments received, floored at 0 per loan, summed
-- across the whole book. One number, in the book's single currency (IDR).
-- No GROUP BY currency: the POC book is single-currency (see P10 for the check).
SELECT
    ROUND(SUM(outstanding_balance), 2) AS outstanding_balance
FROM lakehouse.gold.loan_portfolio_summary;


-- === card: Portfolio · Loans in book | display: scalar | size: 6x3 ===
-- DEFINITION (P3): count of clean (Silver-passing) loans, all statuses.
SELECT
    SUM(loan_count) AS loan_count
FROM lakehouse.gold.loan_portfolio_summary;


-- === card: Portfolio · Principal originated | display: scalar | size: 6x3 | fmt: total_principal=currency ===
-- DEFINITION (P4): gross principal written (not net of repayments), summed across
-- the whole book. One number, in the book's single currency (IDR).
SELECT
    ROUND(SUM(total_principal), 2) AS total_principal
FROM lakehouse.gold.loan_portfolio_summary;


-- === card: Portfolio · Loans by status | display: bar | size: 12x5 | x: loan_status | y: loan_count ===
-- DEFINITION (P5): loan_status is DERIVED from the event lifecycle
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
-- DEFINITION (P6): money still owed per lifecycle status, summed across the book
-- (no currency column — the book is single-currency, so a status total is a real
-- total; P10 is the guard that keeps that true).
SELECT
    loan_status,
    SUM(loan_count)                    AS loan_count,
    ROUND(SUM(outstanding_balance), 2) AS outstanding_balance
FROM lakehouse.gold.loan_portfolio_summary
GROUP BY 1
ORDER BY 3 DESC;


-- === card: Portfolio · Loans by tier | display: bar | size: 12x5 | x: loan_type | y: loan_count ===
-- DEFINITION (P7): loan_type is a DERIVED principal-size tier (no product field in source):
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
-- DEFINITION (P8): total_principal / loan_count within the tier (not the mean of
-- means). One unit, no currency split.
SELECT
    loan_type,
    SUM(loan_count)                                             AS loan_count,
    ROUND(SUM(total_principal) / NULLIF(SUM(loan_count), 0), 2)  AS avg_loan_size
FROM lakehouse.gold.loan_portfolio_summary
GROUP BY 1
ORDER BY CASE loan_type
             WHEN 'micro' THEN 1
             WHEN 'small' THEN 2
             WHEN 'medium' THEN 3
             ELSE 4
         END,
         3 DESC;


-- === card: Portfolio · Status × tier detail | display: table | size: 24x6 | fmt: total_principal=currency,outstanding_balance=currency,avg_loan_size=currency ===
-- DEFINITION (P9): the full mart at its reporting grain, one row per
-- (status × tier) — currency collapsed, since the book is single-currency.
SELECT
    loan_status,
    loan_type,
    SUM(loan_count)                                             AS loan_count,
    ROUND(SUM(total_principal), 2)                              AS total_principal,
    ROUND(SUM(outstanding_balance), 2)                          AS outstanding_balance,
    ROUND(SUM(total_principal) / NULLIF(SUM(loan_count), 0), 2)  AS avg_loan_size
FROM lakehouse.gold.loan_portfolio_summary
GROUP BY 1, 2
ORDER BY 1, CASE loan_type
                WHEN 'micro' THEN 1
                WHEN 'small' THEN 2
                WHEN 'medium' THEN 3
                ELSE 4
            END;


-- === card: Portfolio · Currency codes in book (must be 1) | display: scalar | size: 6x3 ===
-- DEFINITION (P10): COUNT(DISTINCT currency) over the gold mart. This is the
-- GUARD on every aggregated money tile in this pack (P2, P4, P6, P8, P9):
--   1 = the book is single-currency, so those totals are real totals.
--   >1 = the mart carries more than one nominal currency; the totals above are
--        mixed-currency sums and must be re-sliced before they are quoted.
-- This replaced "Book by currency": once the book is one currency there is no
-- split to show, but the invariant still has to be visible on the dashboard.
SELECT
    COUNT(DISTINCT currency) AS currency_codes
FROM lakehouse.gold.loan_portfolio_summary;
