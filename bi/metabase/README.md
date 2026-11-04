# Metabase — NPL reporting artifacts

Paste-ready Trino SQL + UI steps for the two NPL cards. Both queries target the
Gold mart `lakehouse.gold.loan_delinquency` (dbt model
`dbt/models/gold/loan_delinquency.sql`), so they are reproducible after any
`dbt run`.

Prerequisite: the Trino connection must already exist in Metabase (display name
`Lakehouse`, catalog `lakehouse`, schema `gold`) — see `docs/04-metabase.md` §3.
There is no API automation in this repo; cards are built manually in the UI
(`docs/04-metabase.md` §7).

## Card 1 — NPL rate (KPI)

Query file: [`npl_rate_kpi.sql`](npl_rate_kpi.sql)

1. **Metabase → New → Question → Native query** (the SQL editor).
2. Select the **`Lakehouse`** database (the Trino connection).
3. Paste the contents of `npl_rate_kpi.sql`.
4. **Run** — expect one numeric cell (e.g. `0.1234`).
5. Bottom-right **Visualize → Display: Number** (KPI / single number).
6. Column formatting: set field **`npl_rate`** format to **Percent**
   (Metabase multiplies by 100) — `0.1234` renders as `12.34%`.
7. **Save** → name `NPL rate` → add to the target dashboard.

## Card 2 — Delinquency buckets (table)

Query file: [`delinquency_buckets.sql`](delinquency_buckets.sql)

1. **Metabase → New → Question → Native query** → **`Lakehouse`** database.
2. Paste the contents of `delinquency_buckets.sql`.
3. **Run** — expect one row per bucket (`current`, `30-59`, `60-89`, `90-179`,
   `charge-off`) with `loan_count`, `outstanding_balance`, `share_of_book`.
4. **Visualize → Display: Table**.
5. Column formatting: `outstanding_balance` → **Currency** (or plain number);
   `share_of_book` → **Percent**.
6. **Save** → name `Delinquency buckets` → add to the same dashboard.

## Dashboard

- Put `NPL rate` as the headline KPI and `Delinquency buckets` beside it.
- Both are portfolio-level (no filters required).
- Charge-off definition: `charge-off` = ≥180 days past due; `90-179` is
  non-performing but not yet charged off. NPL rate = (90-179 + charge-off) /
  total disbursed loans (defined in `dbt/models/gold/loan_delinquency.sql`).
- To populate every bucket, run the LMS scenario endpoint
  `POST /scenarios/loan-book` (see `src/lms/README.md`), then `dbt run`.
