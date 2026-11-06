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
-- GRAIN (changed by Keystone t_8cbf9a27, materialized by Piston t_b9c989e7):
--   gold.loan_event_daily       → (event_date, currency)
--   silver.repayment_schedule   → + currency (denormalized from the parent loan)
--
-- MONEY UNITS — READ BEFORE EDITING A MONEY CARD:
--   disbursement_amount / payment_amount / principal_due / interest_due are NOMINAL
--   PER CURRENCY. There is NO FX conversion (option (a), see
--   models/gold/loan_portfolio_summary.sql) — SUM-ing a money column across currencies
--   produces a mixed-currency nominal figure, which is NOT a real total.
--   => every money tile here is sliced by `currency`:
--        Y1, Y2, Y3, Y7  one bar per currency
--        Y5, Y6          one row per currency (table)
--        Y8, Y10         one series per currency (conditional aggregates)
--        Y9              (event_date, currency) table — unpivoted, every code
--   => ratios (Y4 collection_rate, Y6 paid_share) are DIMENSIONLESS and safe across
--      currencies; they are the only tiles allowed to collapse the currency dimension.
--   => counts (Y5 installments, Y6 counts) are currency-agnostic and total safely.
--   There is intentionally no single cross-currency payments money number.
--
-- PIVOT COUPLING (Y8, Y10): the per-currency series are conditional aggregates over
--   the six ISO-4217 codes the LMS accepts (src/lms/constants.py VALID_CURRENCIES:
--   USD, EUR, GBP, JPY, CAD, AUD), enforced upstream by the dbt `accepted_values`
--   tests on both currency columns. Trino has no dynamic PIVOT and the provisioner
--   supports ONE graph dimension per card, so the list is written out. If that list
--   ever grows, update Y8 and Y10 in the same commit: Y9's table is unpivoted and
--   keeps printing every code, and the Y1/Y2 bars are the coverage check — a currency
--   present there but missing from Y8/Y10 means the pivot is stale.
-- =============================================================================


-- === card: Payments · Total collected (cash) | display: bar | size: 12x5 | x: currency | y: total_collected | fmt: total_collected=currency ===
-- DEFINITION (cash basis): sum of all 'payment' loan_event amounts, all time, PER CURRENCY.
-- One bar per ISO-4217 currency: each bar is a real amount in its own unit.
-- Replaces the old single scalar, which added six currencies into a meaningless total.
SELECT
    currency,
    ROUND(SUM(payment_amount), 2) AS total_collected
FROM lakehouse.gold.loan_event_daily
GROUP BY 1
ORDER BY 2 DESC;


-- === card: Payments · Total disbursed (cash) | display: bar | size: 12x5 | x: currency | y: total_disbursed | fmt: total_disbursed=currency ===
-- DEFINITION (cash basis): sum of all 'disbursement' loan_event amounts, all time, PER CURRENCY.
-- Replaces the old single scalar, which added six currencies into a meaningless total.
SELECT
    currency,
    ROUND(SUM(disbursement_amount), 2) AS total_disbursed
FROM lakehouse.gold.loan_event_daily
GROUP BY 1
ORDER BY 2 DESC;


-- === card: Payments · Overdue amount (schedule) | display: bar | size: 12x5 | x: currency | y: overdue_amount | fmt: overdue_amount=currency ===
-- DEFINITION (schedule basis): principal_due + interest_due of instalments whose
-- status is 'overdue', PER CURRENCY. Status is maintained upstream by the LMS —
-- gold does not re-derive it. A currency with no overdue instalment has no bar
-- (correct: zero exposure, not a missing row).
SELECT
    currency,
    ROUND(SUM(principal_due + interest_due), 2) AS overdue_amount
FROM lakehouse.silver.repayment_schedule
WHERE status = 'overdue'
GROUP BY 1
ORDER BY 2 DESC;


-- === card: Payments · Collection rate on due-to-date instalments | display: scalar | size: 6x3 | fmt: collection_rate=percent ===
-- DEFINITION (schedule basis): paid amount / (paid + overdue amount).
-- Excludes 'scheduled' (not yet due) from both sides — this is a due-date-cohort
-- collection rate, not a lifetime recovery rate.
-- UNITS: a ratio of two nominal sums, so it is dimensionless and safe across
-- currencies. It is the ONE tile in this pack that pools currencies by design —
-- do not read it as a per-currency rate (Y5/Y6 give the per-currency amounts).
SELECT
    ROUND(
        SUM(principal_due + interest_due) FILTER (WHERE status = 'paid')
        / NULLIF(
            SUM(principal_due + interest_due) FILTER (WHERE status IN ('paid', 'overdue')),
            0
        ), 4) AS collection_rate
FROM lakehouse.silver.repayment_schedule;


-- === card: Payments · Installments by status | display: table | size: 12x6 | fmt: amount_due=currency ===
-- One row per (currency, status): count is currency-agnostic, amount_due is nominal
-- in that row's currency. Never total amount_due down the table without splitting by currency.
SELECT
    currency,
    status,
    COUNT(*)                                       AS installments,
    ROUND(SUM(principal_due + interest_due), 2)     AS amount_due
FROM lakehouse.silver.repayment_schedule
GROUP BY 1, 2
ORDER BY 1, 3 DESC;


-- === card: Payments · Installment rollforward by due month | display: table | size: 24x6 | fmt: paid_amount=currency,overdue_amount=currency,scheduled_amount=currency,paid_share=percent ===
-- DEFINITION: for each (due month, currency), instalment counts and amounts split by
-- status, plus paid_share = paid / (paid + overdue) for that month AND currency
-- (due-to-date only, dimensionless). Amounts are nominal in the row's currency.
SELECT
    SUBSTR(CAST(due_date AS varchar), 1, 7)                                          AS due_month,
    currency,
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
GROUP BY 1, 2
ORDER BY 1, 2;


-- === card: Payments · Paid vs overdue by currency | display: bar | size: 12x5 | x: currency | y: paid_amount,overdue_amount | fmt: paid_amount=currency,overdue_amount=currency ===
-- DEFINITION: two-series bar of the paid vs overdue instalment amounts, PER CURRENCY,
-- all due months. Each bar is a real amount in that currency.
-- WHY NOT BY DUE MONTH: month × currency would need 12 series (2 metrics × 6
-- currencies) on one axis, which is unreadable; and summing the two metrics per
-- month across currencies is the mixed-currency figure this pack forbids. The month
-- detail — with currency — lives in Y6 (table). (Was "Paid vs overdue by due month".)
SELECT
    currency,
    COALESCE(ROUND(SUM(principal_due + interest_due) FILTER (WHERE status = 'paid'), 2), 0)    AS paid_amount,
    COALESCE(ROUND(SUM(principal_due + interest_due) FILTER (WHERE status = 'overdue'), 2), 0) AS overdue_amount
FROM lakehouse.silver.repayment_schedule
GROUP BY 1
ORDER BY 1;


-- === card: Payments · Collections by day (cash) | display: line | size: 24x5 | x: event_date | y: payment_usd,payment_eur,payment_gbp,payment_jpy,payment_cad,payment_aud | fmt: payment_usd=currency,payment_eur=currency,payment_gbp=currency,payment_jpy=currency,payment_cad=currency,payment_aud=currency ===
-- DEFINITION (cash basis): payment events summed per calendar day (UTC event date),
-- ONE SERIES PER CURRENCY. No point on this chart is a cross-currency sum.
-- A currency/day with no movement has no row in the mart; the outer SUM then yields
-- NULL and COALESCE turns it into 0 so every series stays continuous.
-- Axis note: all series share one nominal axis — compare each series to itself over
-- time, not to the other currencies (no FX conversion).
SELECT
    event_date,
    COALESCE(ROUND(SUM(payment_amount) FILTER (WHERE currency = 'USD'), 2), 0) AS payment_usd,
    COALESCE(ROUND(SUM(payment_amount) FILTER (WHERE currency = 'EUR'), 2), 0) AS payment_eur,
    COALESCE(ROUND(SUM(payment_amount) FILTER (WHERE currency = 'GBP'), 2), 0) AS payment_gbp,
    COALESCE(ROUND(SUM(payment_amount) FILTER (WHERE currency = 'JPY'), 2), 0) AS payment_jpy,
    COALESCE(ROUND(SUM(payment_amount) FILTER (WHERE currency = 'CAD'), 2), 0) AS payment_cad,
    COALESCE(ROUND(SUM(payment_amount) FILTER (WHERE currency = 'AUD'), 2), 0) AS payment_aud
FROM lakehouse.gold.loan_event_daily
GROUP BY 1
ORDER BY 1;


-- === card: Payments · Disbursement vs collection by day | display: table | size: 24x6 | fmt: disbursement_amount=currency,payment_amount=currency,net_flow=currency ===
-- DEFINITION (cash basis): per calendar day AND currency, money out (disbursement)
-- vs money in (payment) and the difference. This is the audit view behind Y8/Y10 —
-- it prints every currency present, including any code the Y8/Y10 pivot does not
-- know about (that is the coverage check).
-- TABLE, not a chart: 12 series (2 metrics × 6 currencies) on one axis is unreadable,
-- and any collapse to a single daily total would be a mixed-currency sum.
SELECT
    event_date,
    currency,
    ROUND(disbursement_amount, 2)                       AS disbursement_amount,
    ROUND(payment_amount, 2)                            AS payment_amount,
    ROUND(payment_amount - disbursement_amount, 2)       AS net_flow
FROM lakehouse.gold.loan_event_daily
ORDER BY event_date, currency;


-- === card: Payments · Net cash flow by day | display: line | size: 24x5 | x: event_date | y: net_flow_usd,net_flow_eur,net_flow_gbp,net_flow_jpy,net_flow_cad,net_flow_aud | fmt: net_flow_usd=currency,net_flow_eur=currency,net_flow_gbp=currency,net_flow_jpy=currency,net_flow_cad=currency,net_flow_aud=currency ===
-- DEFINITION: payment_amount - disbursement_amount per day AND currency
-- (negative = net lending that day in that currency), one series per currency.
-- Same axis note as Y8: nominal per currency, no FX conversion between series.
SELECT
    event_date,
    COALESCE(ROUND(SUM(payment_amount - disbursement_amount) FILTER (WHERE currency = 'USD'), 2), 0) AS net_flow_usd,
    COALESCE(ROUND(SUM(payment_amount - disbursement_amount) FILTER (WHERE currency = 'EUR'), 2), 0) AS net_flow_eur,
    COALESCE(ROUND(SUM(payment_amount - disbursement_amount) FILTER (WHERE currency = 'GBP'), 2), 0) AS net_flow_gbp,
    COALESCE(ROUND(SUM(payment_amount - disbursement_amount) FILTER (WHERE currency = 'JPY'), 2), 0) AS net_flow_jpy,
    COALESCE(ROUND(SUM(payment_amount - disbursement_amount) FILTER (WHERE currency = 'CAD'), 2), 0) AS net_flow_cad,
    COALESCE(ROUND(SUM(payment_amount - disbursement_amount) FILTER (WHERE currency = 'AUD'), 2), 0) AS net_flow_aud
FROM lakehouse.gold.loan_event_daily
GROUP BY 1
ORDER BY 1;
