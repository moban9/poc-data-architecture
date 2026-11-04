-- Metabase native query — delinquency-bucket table card.
--
-- One row per bucket: loan_count, outstanding_balance, and share_of_book
-- (the bucket's share of the total outstanding balance across all buckets).
-- Buckets are ordered by severity, not alphabetically.
SELECT
    delinquency_bucket,
    loan_count,
    outstanding_balance,
    round(outstanding_balance / SUM(outstanding_balance) OVER (), 4) AS share_of_book
FROM lakehouse.gold.loan_delinquency
ORDER BY
    CASE delinquency_bucket
        WHEN 'current' THEN 1
        WHEN '30-59' THEN 2
        WHEN '60-89' THEN 3
        WHEN '90-179' THEN 4
        WHEN 'charge-off' THEN 5
    END;
