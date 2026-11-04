-- Metabase native query — NPL rate KPI card.
--
-- lakehouse.gold.loan_delinquency carries the SAME portfolio-level npl_rate on
-- every row (the Gold model computes it once as (90-179 + charge-off) / total
-- disbursed loans). Collapse to a single row for a KPI/single-number card.
SELECT
    MAX(npl_rate) AS npl_rate
FROM lakehouse.gold.loan_delinquency;
