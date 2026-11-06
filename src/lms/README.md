# LMS source service

FastAPI REST API over the Postgres LMS source database (`loan`, `loan_event`,
`borrower`, `repayment_schedule`). The demo control panel (`demo/app.py`) drives this API to inject
data upstream of Debezium CDC → Kafka → Iceberg → dbt.

## Endpoints

| Method | Path | Purpose |
|--------|------|---------|
| GET    | `/health` | liveness + db connectivity |
| GET    | `/` | service metadata |
| POST   | `/generate?count=N&mode=clean\|dirty\|mixed` | insert N loans (+ events) |
| POST   | `/loans/{loan_id}/disburse` | record a disbursement event |
| POST   | `/payments` | record a payment event (`{"loan_id", "amount", "occurred_at"?}`) |
| POST   | `/scenarios/loan-book` | create loans with a real repayment schedule so every Gold delinquency bucket is populated (`{"n_per_bucket": N}`) |

## Repayment contract (NPL)

Every loan carries a real repayment schedule so days-past-due is derived from an
actual due date — not a 365-day term assumption:

| column | table | type | meaning |
|--------|-------|------|---------|
| `term_months` | `loan` | int | variable term, default 12 |
| `disbursement_date` | `loan` | varchar `YYYY-MM-DD` | schedule amortization anchor |
| `interest_rate` | `loan` | numeric(5,2) | annual rate in percent (12.00 = 12%) |
| `monthly_installment` | `loan` | numeric(18,2) | equal monthly annuity (PMT) |
| `maturity_date` | `loan` | varchar `YYYY-MM-DD` | final due date (= last schedule row) |
| `installment_no` / `due_date` | `repayment_schedule` | int / varchar | one row per instalment |
| `principal_due` / `interest_due` | `repayment_schedule` | numeric(18,2) | amortized split |
| `status` | `repayment_schedule` | varchar | `scheduled` / `paid` / `overdue` |

`loan.amount` remains the principal (no separate `principal_amount` column —
kept non-breaking with the existing Silver/Gold contract). Dates are ISO strings
(`VARCHAR(16)`) to match `origination_date` and avoid a Debezium Postgres
`DATE` → int32 decode in Bronze/Silver.

## Delinquency / NPL loan book (`POST /scenarios/loan-book`)

Creates, in one transaction, `n_per_bucket` loans per delinquency bucket. Each
loan carries a real repayment schedule: it amortizes monthly from
`disbursement_date`, the first `paid_installments` are settled on time, then the
loan stops paying. The oldest overdue `repayment_schedule.due_date` encodes the
loan's days-past-due (the Gold model derives `dpd = as_of − oldest overdue
due_date`).

| bucket | days past due | Gold `loan_delinquency` bucket |
|--------|---------------|--------------------------------|
| `on_time`     | 0   | `current` |
| `dpd_30_59`   | 45  | `30-59`   |
| `dpd_60_89`   | 75  | `60-89`   |
| `dpd_90_plus` | 120 | `90+`     |
| `charge_off`  | 200 | `90+`     |

Total paid stays under principal, so outstanding balance is always > 0. New ids
are generated and no rows are ever deleted, so the endpoint is safe to call
repeatedly. (≥180 days past due is still `90+` — there is no charge-off tier.)


## Dirty modes (map 1:1 to dbt Silver DQ tests)

| mode | defect | dbt test tripped |
|------|--------|------------------|
| `null_loan_id` | `loan_event.loan_id` is NULL | `not_null` + `relationships` |
| `negative_amount` | `loan.amount` <= 0 | `positive_value` |
| `invalid_date` | `loan.origination_date` = "not-a-date" | `valid_date` |
| `orphan_borrower_id` | `loan.borrower_id` = "B-9999" | `relationships` |

The source schema deliberately has **no FK/check constraints** so these defects
can be written and flow downstream — dbt is the enforcement layer.

## Run

```bash
export DATABASE_URL=postgresql://lms:lms@localhost:5432/lms
python seed.py                 # idempotent: create tables + seed B-1001..B-1004
uvicorn app:app --host 0.0.0.0 --port 8000
```

or via compose (see `docker-compose.lms-api.yml` snippet / main
`compose/docker-compose.yml`).

## Re-snapshot after a schema change

Adding columns/tables (like the repayment contract) needs a fresh Debezium
snapshot to re-capture existing rows into Bronze:

```bash
cd compose && ./connectors/resnapshot.sh
```
