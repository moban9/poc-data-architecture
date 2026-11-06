# t_43530a0f — Bronze repayment_schedule reconcile + silver/gold rebuild

**Owner:** Cask · **Date:** 2026-11-05 · **Status:** COMPLETE

## Outcome
bronze.repayment_schedule reconciled to 6,908,334 installments (one row per id),
silver/gold rebuilt, all DQ tests green except the 5 intentional dirty_data seed tests,
dashboard 3 payments cards now return complete data.

## 1. Bronze reconcile (verified)
- Before: bronze.repayment_schedule = 14,347,023 rows / 6,908,334 distinct ids
  (7,438,689 CDC-replay duplicates).
- Source (lms-postgres) repayment_schedule = 6,908,334 rows, id unique.
- Dedupe: `row_number() over (partition by id order by "_cdc"."ts" desc nulls last,
  "_cdc"."offset" desc nulls last) = 1` — memory-safe (window projects only id + the
  two sort keys; full rows joined back on the globally-unique `_cdc`.`offset`). CTAS 71.9s.
- After: bronze.repayment_schedule = 6,908,334 rows / 6,908,334 distinct id == source.
- Backup kept: `lakehouse.bronze.repayment_schedule_pre_dedupe_20261105`
  (14,347,023 rows) — matches the loan/loan_event `_pre_dedupe_20261105` convention.
- iceberg-sink PAUSED across the rename (removes the auto-create race), RESUMED + RUNNING after.

## 2. dbt run + test (verified)
- `cd /home/ubuntu/poc/compose && docker compose -f docker-compose.yml -f monitoring.yml -f traefik.yml run --rm dbt`
- dbt run: 16/16 models OK. stg_repayment_schedule = 6,908,334;
  silver.repayment_schedule = 6,580,511 (clean-loan complement).
- dbt test: 64 PASS / 5 FAIL.
  - unique_repayment_schedule_id: **PASS**
  - relationships_loan_event_loan_id: **PASS**
  - The 5 failures are exactly the intentional dirty_data seed tests
    (accepted_values_currency, not_null_id, positive_value_amount,
    relationships_borrower_id, valid_date_origination_date).

## 3. Dashboard 3 payments cards (verified)
Ran the exact card SQL against Trino (Metabase caching off → same data path):
- silver.repayment_schedule = 6,580,511 rows, 6,580,511 distinct ids AND distinct
  (loan_id, installment_no) → no dupes, no orphans.
- Y3 overdue by currency: 6 rows; Y4 collection rate 0.6042; Y5 installments by
  status 18 rows; Y1/Y2 cash collected/disbursed 6 rows each; Y6 rollforward 60 months.
- All cards return real, non-empty data.

## Evidence (on-disk)
- dbt/evidence/cask_dedupe_create.log
- dbt/evidence/cask_verify_rename.log
- dbt/evidence/cask_dbt_run.log
- dbt/evidence/cask_dashboard3.log

## Notes / follow-ups (not blocking)
- Sink is still append-only (Iceberg Connect 1.9.2 has no upsert): NEW duplicates can
  reappear on a hard Connect crash until a different writer is approved (docs/09 §5
  option A, pending Atlas). The dedupe SQL is re-runnable.
- loan_pre_dedupe_20261105 / loan_event_pre_dedupe_20261105 (CEO cleanup backups) kept.
- Minor: trailing "Syntax error: Unterminated quoted string" in the dbt compose run,
  AFTER metrics were pushed and "=== done ===" — cosmetic, non-blocking.
