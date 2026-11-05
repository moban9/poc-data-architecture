-- =============================================================================
-- Card pack 03 — PAYMENTS / COLLECTIONS
-- Dashboard: LMS POC — Business Performance (Gold)   ·   Owner: Prism (BI)
-- Sources:
--   lakehouse.gold.loan_event_daily          — cash actually moved (dbt models/gold/loan_event_daily.sql)
--   lakehouse.silver.repayment_schedule      — contractual instalments & their status
--                                               (dbt models/silver/repayment_schedule.sql)
--
-- TWO DIFFERENT BASES — do not mix them in one tile:
--   cash basis    : loan_event payment events (money received)
--   schedule basis: principal_due + interest_due by instalment status (money owed)
-- =============================================================================


-- === card: Payments · Total collected (cash) | display: scalar | size: 6x3 | fmt: total_collected=currency ===
-- DEFINITION (cash basis): sum of all 'payment' loan_event amounts, all time.
SELECT
    ROUND(SUM(payment_amount), 2) AS total_collected
FROM lakehouse.gold.loan_event_daily;


-- === card: Payments · Total disbursed (cash) | display: scalar | size: 6x3 | fmt: total_disbursed=currency ===
-- DEFINITION (cash basis): sum of all 'disbursement' loan_event amounts, all time.
SELECT
    ROUND(SUM(disbursement_amount), 2) AS total_disbursed
FROM lakehouse.gold.loan_event_daily;


-- === card: Payments · Overdue amount (schedule) | display: scalar | size: 6x3 | fmt: overdue_amount=currency ===
-- DEFINITION (schedule basis): principal_due + interest_due of instalments whose
-- status is 'overdue'. Status is maintained upstream by the LMS — gold does not re-derive it.
SELECT
    COALESCE(ROUND(SUM(principal_due + interest_due), 2), 0) AS overdue_amount
FROM lakehouse.silver.repayment_schedule
WHERE status = 'overdue';


-- === card: Payments · Collection rate on due-to-date instalments | display: scalar | size: 6x3 | fmt: collection_rate=percent ===
-- DEFINITION (schedule basis): paid amount / (paid + overdue amount).
-- Excludes 'scheduled' (not yet due) from both sides — this is a due-date-cohort
-- collection rate, not a lifetime recovery rate.
SELECT
    ROUND(
        SUM(principal_due + interest_due) FILTER (WHERE status = 'paid')
        / NULLIF(
            SUM(principal_due + interest_due) FILTER (WHERE status IN ('paid', 'overdue')),
            0
        ), 4) AS collection_rate
FROM lakehouse.silver.repayment_schedule;


-- === card: Payments · Installments by status | display: table | size: 12x4 | fmt: amount_due=currency ===
SELECT
    status,
    COUNT(*)                                       AS installments,
    ROUND(SUM(principal_due + interest_due), 2)     AS amount_due
FROM lakehouse.silver.repayment_schedule
GROUP BY 1
ORDER BY 2 DESC;


-- === card: Payments · Installment rollforward by due month | display: table | size: 24x6 | fmt: paid_amount=currency,overdue_amount=currency,scheduled_amount=currency,paid_share=percent ===
-- DEFINITION: for each due month, instalment counts and amounts split by status,
-- plus paid_share = paid / (paid + overdue) for that month (due-to-date only).
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


-- === card: Payments · Paid vs overdue by due month | display: bar | size: 24x5 | x: due_month | y: paid_amount,overdue_amount | fmt: paid_amount=currency,overdue_amount=currency ===
SELECT
    SUBSTR(CAST(due_date AS varchar), 1, 7)                                          AS due_month,
    COALESCE(ROUND(SUM(principal_due + interest_due) FILTER (WHERE status = 'paid'), 2), 0)    AS paid_amount,
    COALESCE(ROUND(SUM(principal_due + interest_due) FILTER (WHERE status = 'overdue'), 2), 0) AS overdue_amount
FROM lakehouse.silver.repayment_schedule
GROUP BY 1
ORDER BY 1;


-- === card: Payments · Collections by day (cash) | display: line | size: 12x5 | x: event_date | y: payment_amount | fmt: payment_amount=currency ===
-- DEFINITION (cash basis): payment events summed per calendar day (UTC event date).
SELECT
    event_date,
    payment_amount
FROM lakehouse.gold.loan_event_daily
ORDER BY event_date;


-- === card: Payments · Disbursement vs collection by day | display: line | size: 12x5 | x: event_date | y: disbursement_amount,payment_amount | fmt: disbursement_amount=currency,payment_amount=currency ===
SELECT
    event_date,
    disbursement_amount,
    payment_amount
FROM lakehouse.gold.loan_event_daily
ORDER BY event_date;


-- === card: Payments · Net cash flow by day | display: line | size: 24x5 | x: event_date | y: net_flow | fmt: net_flow=currency ===
-- DEFINITION: payment_amount - disbursement_amount per day (negative = net lending).
SELECT
    event_date,
    ROUND(payment_amount - disbursement_amount, 2) AS net_flow
FROM lakehouse.gold.loan_event_daily
ORDER BY event_date;
