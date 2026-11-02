# LMS source service

FastAPI REST API over the Postgres LMS source database (`loan`, `loan_event`,
`borrower`). The demo control panel (`demo/app.py`) drives this API to inject
data upstream of Debezium CDC → Kafka → Iceberg → dbt.

## Endpoints

| Method | Path | Purpose |
|--------|------|---------|
| GET    | `/health` | liveness + db connectivity |
| GET    | `/` | service metadata |
| POST   | `/generate?count=N&mode=clean\|dirty\|mixed` | insert N loans (+ events) |
| POST   | `/loans/{loan_id}/disburse` | record a disbursement event |
| POST   | `/payments` | record a payment event (`{"loan_id", "amount", "occurred_at"?}`) |

## Dirty modes (map 1:1 to dbt Silver DQ tests)

| mode | defect | dbt test tripped |
|------|--------|------------------|
| `null_loan_id` | `loan_event.loan_id` is NULL | `not_null` + `relationships` |
| `negative_amount` | `loan.amount` <= 0 | `positive_value` |
| `invalid_date` | `loan.origination_date` = "not-a-date" | `valid_date` |
| `unsupported_currency` | `loan.currency` = "XYZ" | `accepted_values` |
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
