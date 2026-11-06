-- =============================================================================
-- Card pack 03 — PAYMENTS / COLLECTIONS
-- Dashboard: LMS POC — Business Performance   ·   Owner: Prism (BI)
-- Sources:
--   lakehouse.gold.loan_event_daily          — cash actually moved (dbt models/gold/loan_event_daily.sql)
--   lakehouse.silver.repayment_schedule      — contractual instalments & their status
--                                               (dbt models/silver/repayment_schedule.sql)
--
-- TWO DIFFERENT BASES — do not mix them in one tile:
--   cash basis    : loan_event payment events (money received)
--   schedule basis: principal_due + interest_due by instalment status (money owed)
--
-- GRAIN: gold.loan_event_daily is (event_date, currency); silver.repayment_schedule
--   carries currency denormalized from the parent loan. Both are FINER than these
--   cards need: the POC book is single-currency (IDR) — Randy's call, task
--   t_d2573cb4 — so every money tile below aggregates across the book with NO
--   currency dimension and prints ONE real total (or one series / one row set).
--
-- MONEY UNITS — READ BEFORE EDITING A MONEY CARD:
--   disbursement_amount / payment_amount / principal_due / interest_due are nominal
--   amounts in the book's single currency (IDR). A SUM spanning more than one
--   currency would be a mixed-currency nominal figure with no FX conversion behind
--   it, so the invariant is checked on the dashboard, not assumed here:
--       portfolio card "Portfolio · Currency codes in book (must be 1)"
--         = COUNT(DISTINCT currency) over gold.loan_portfolio_summary.
--   If that card reads > 1, re-slice these tiles by currency before quoting them.
--   Ratios (Y4 collection_rate, Y6 paid_share) are DIMENSIONLESS and need no unit.
-- =============================================================================


-- === card: Payments · Total collected (cash) | display: scalar | size: 6x3 | fmt: total_collected=currency ===
-- DEFINITION (Y1, cash basis): sum of all 'payment' loan_event amounts, all time,
-- across the whole book. One number in the book's single currency (IDR).
SELECT
    ROUND(SUM(payment_amount), 2) AS total_collected
FROM lakehouse.gold.loan_event_daily;


-- === card: Payments · Total disbursed (cash) | display: scalar | size: 6x3 | fmt: total_disbursed=currency ===
-- DEFINITION (Y2, cash basis): sum of all 'disbursement' loan_event amounts, all
-- time, across the whole book. One number in the book's single currency (IDR).
SELECT
    ROUND(SUM(disbursement_amount), 2) AS total_disbursed
FROM lakehouse.gold.loan_event_daily;


-- === card: Payments · Overdue amount (schedule) | display: scalar | size: 6x3 | fmt: overdue_amount=currency ===
-- DEFINITION (Y3, schedule basis): principal_due + interest_due of instalments whose
-- status is 'overdue', across the whole book. Status is maintained upstream by the
-- LMS — gold does not re-derive it.
SELECT
    ROUND(SUM(principal_due + interest_due), 2) AS overdue_amount
FROM lakehouse.silver.repayment_schedule
WHERE status = 'overdue';


-- === card: Payments · Collection rate on due-to-date instalments | display: scalar | size: 6x3 | fmt: collection_rate=percent ===
-- DEFINITION (Y4, schedule basis): paid amount / (paid + overdue amount).
-- Excludes 'scheduled' (not yet due) from both sides — this is a due-date-cohort
-- collection rate, not a lifetime recovery rate.
-- UNITS: a ratio of two nominal sums, so it is dimensionless and needs no currency.
SELECT
    ROUND(
        SUM(principal_due + interest_due) FILTER (WHERE status = 'paid')
        / NULLIF(
            SUM(principal_due + interest_due) FILTER (WHERE status IN ('paid', 'overdue')),
            0
        ), 4) AS collection_rate
FROM lakehouse.silver.repayment_schedule;


-- === card: Payments · Installments by status | display: table | size: 12x6 | fmt: amount_due=currency ===
-- DEFINITION (Y5, schedule basis): one row per instalment status with the count and
-- the amount owed in that status, summed across the whole book.
SELECT
    status,
    COUNT(*)                                    AS installments,
    ROUND(SUM(principal_due + interest_due), 2)  AS amount_due
FROM lakehouse.silver.repayment_schedule
GROUP BY 1
ORDER BY 3 DESC;


-- === card: Payments · Installment rollforward by due month | display: table | size: 24x6 | fmt: paid_amount=currency,overdue_amount=currency,scheduled_amount=currency,paid_share=percent ===
-- DEFINITION (Y6, schedule basis): for each contractual due month, instalment counts
-- and amounts split by status, plus paid_share = paid / (paid + overdue) for that
-- month (due-to-date only, dimensionless).
SELECT
    SUBSTR(CAST(due_date AS varchar), 1, 7)                                          AS due_month,
    COUNT(*)                                                                          AS installments,
    COUNT(*) FILTER (WHERE status = 'paid')                                          AS paid_count,
    COUNT(*) FILTER (WHERE status = 'overdue')                                       AS overdue_count,
    COUNT(*) FILTER (WHERE status = 'scheduled')                                     AS scheduled_count,
    COALESCE(ROUND(SUM(principal_due + interest_due) FILTER (WHERE status = 'paid'), 2), 0)      AS paid_amount,
    COALESCE(ROUND(SUM(principal_due + interest_due) FILTER (WHERE status = 'overdue'), 2), 0)   AS overdue_amount,
    COALESCE(ROUND(SUM(principal_due + interest_due) FILTER (WHERE status = 'scheduled'), 2), 0) AS scheduled_amount,
    ROUND(
        SUM(principal_due + interest_due) FILTER (WHERE status = 'paid')
        / NULLIF(SUM(principal_due + interest_due) FILTER (WHERE status IN ('paid', 'overdue')), 0),
        4)                                                                            AS paid_share
FROM lakehouse.silver.repayment_schedule
GROUP BY 1
ORDER BY 1;


-- === card: Payments · Paid vs overdue by due month | display: bar | size: 12x5 | x: due_month | y: paid_amount,overdue_amount | fmt: paid_amount=currency,overdue_amount=currency ===
-- DEFINITION (Y7, schedule basis): two-series bar of the paid vs overdue instalment
-- amounts per contractual due month — when the book started slipping, and how much
-- of each month's dues has actually been collected. Amounts aggregate over the book
-- (single currency, so the two series share one real axis).
SELECT
    SUBSTR(CAST(due_date AS varchar), 1, 7)                                                   AS due_month,
    COALESCE(ROUND(SUM(principal_due + interest_due) FILTER (WHERE status = 'paid'), 2), 0)    AS paid_amount,
    COALESCE(ROUND(SUM(principal_due + interest_due) FILTER (WHERE status = 'overdue'), 2), 0) AS overdue_amount
FROM lakehouse.silver.repayment_schedule
GROUP BY 1
ORDER BY 1;


-- === card: Payments · Collections by day (cash) | display: line | size: 24x5 | x: event_date | y: payment_amount | fmt: payment_amount=currency ===
-- DEFINITION (Y8, cash basis): payment events summed per calendar day (UTC event date),
-- across the whole book — the collections trend. One line, one currency.
SELECT
    event_date,
    ROUND(SUM(payment_amount), 2) AS payment_amount
FROM lakehouse.gold.loan_event_daily
GROUP BY 1
ORDER BY 1;


-- === card: Payments · Disbursement vs collection by day | display: table | size: 24x6 | fmt: disbursement_amount=currency,payment_amount=currency,net_flow=currency ===
-- DEFINITION (Y9, cash basis): per calendar day, money out (disbursement) vs money in
-- (payment) and the difference — the daily audit view behind Y8/Y10.
-- The mart is (event_date, currency); this card sums it to one row per day.
SELECT
    event_date,
    ROUND(SUM(disbursement_amount), 2)                   AS disbursement_amount,
    ROUND(SUM(payment_amount), 2)                        AS payment_amount,
    ROUND(SUM(payment_amount - disbursement_amount), 2)  AS net_flow
FROM lakehouse.gold.loan_event_daily
GROUP BY 1
ORDER BY 1;


-- === card: Payments · Net cash flow by day | display: line | size: 24x5 | x: event_date | y: net_flow | fmt: net_flow=currency ===
-- DEFINITION (Y10, cash basis): payment_amount - disbursement_amount per calendar day
-- across the whole book (negative = net lending that day). One line, one currency.
SELECT
    event_date,
    ROUND(SUM(payment_amount - disbursement_amount), 2) AS net_flow
FROM lakehouse.gold.loan_event_daily
GROUP BY 1
ORDER BY 1;
