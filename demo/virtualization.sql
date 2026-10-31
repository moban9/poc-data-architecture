# Data virtualization demo — run the SAME query in Trino and DuckDB against the
# ONE Polaris catalog. Both must return identical numbers (the "so what").
#
# TODO(Meridian/Cask): finalize the Gold table name (e.g. gold.loan_portfolio)
# and the Polaris catalog URI + S3/MinIO credentials once the lake is wired.

-- ── 1. Trino (transform + serve) ──────────────────────────────
-- run via: docker compose exec trino trino
SELECT
  product_type,
  COUNT(DISTINCT loan_id)  AS loans,
  SUM(principal)           AS outstanding,
  AVG(days_past_due)       AS avg_dpd
FROM gold.loan_portfolio
WHERE as_of_date = DATE '2026-10-30'
GROUP BY product_type
ORDER BY outstanding DESC;

-- ── 2. DuckDB (ad-hoc, single binary) ─────────────────────────
-- run via: docker compose run --rm duckdb
-- (same query text, same Polaris REST endpoint, same result)
INSTALL iceberg;
LOAD iceberg;
ATTACH 'http://polaris:8181/api/catalog' AS pol (TYPE iceberg, ENDPOINT_TYPE rest);

SELECT
  product_type,
  COUNT(DISTINCT loan_id)  AS loans,
  SUM(principal)           AS outstanding,
  AVG(days_past_due)       AS avg_dpd
FROM pol.gold.loan_portfolio
WHERE as_of_date = DATE '2026-10-30'
GROUP BY product_type
ORDER BY outstanding DESC;
