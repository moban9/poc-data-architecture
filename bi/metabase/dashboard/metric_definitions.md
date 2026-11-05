# Metric definitions — LMS POC business dashboard

One line per tile. If a number on the dashboard is questioned, this file answers it
without opening dbt. Every metric below is computed by a real query in `sql/*.sql`
against the gold/silver layer — nothing is typed in by hand.

**Dashboard:** `LMS POC — Business Performance (Gold)` · **Owner:** Prism (BI) ·
**Audience:** Randy (POC demo / exec read) · Atlas (data-lead review) · Keystone (pipeline owner)

**As-of:** all gold marts are point-in-time builds. "Now" for the dataset is
`MAX(silver.loan_event.occurred_at)`, shown on the dashboard as **Data as of**.
Re-running `dbt run` after the LMS scenario endpoint `POST /scenarios/loan-book`
moves that date and every number with it.

**Money units:** nominal amount, summed across all currencies present in the book
(USD/EUR/GBP/JPY/CAD/AUD). No FX conversion exists in the gold layer — see *Known gaps*.

---

## Portfolio health — source `lakehouse.gold.loan_portfolio_summary`

| # | Tile | Definition | Formula |
|---|---|---|---|
| P1 | Data as of | Latest event timestamp in the lakehouse = the dataset's "now" | `MAX(occurred_at)::date` over `silver.loan_event` |
| P2 | Outstanding balance | Principal still owed, floored at 0 per loan | `SUM(outstanding_balance)`; mart computes `GREATEST(principal - payments, 0)` |
| P3 | Loans in book | Loans that passed Silver DQ | `SUM(loan_count)` |
| P4 | Principal originated | Gross principal written, not net of repayments | `SUM(total_principal)` |
| P5 | Loans by status | Count split by derived lifecycle status | `SUM(loan_count) GROUP BY loan_status` |
| P6 | Outstanding by status | Money still owed, split by status | `SUM(outstanding_balance) GROUP BY loan_status` |
| P7 | Loans by tier | Count split by derived principal-size tier | `SUM(loan_count) GROUP BY loan_type` |
| P8 | Avg loan size by tier | Principal per loan within tier (not mean of means) | `SUM(total_principal)/SUM(loan_count)` |
| P9 | Status × tier detail | The mart at native grain | one row per (`loan_status`,`loan_type`) |
| P10 | Book by currency | Currency exposure — **silver, not gold** | `COUNT(*)`, `SUM(amount) GROUP BY currency` over `silver.loan` |

**Derived dimensions (there is no status/product column in the LMS source):**
- `loan_status`: `originated` = origination event, no disbursement · `disbursed` = funded, no payment · `repaying` = funded and ≥1 payment.
- `loan_type`: `micro` < 25,000 · `small` 25,000–49,999 · `medium` 50,000–74,999 · `large` ≥ 75,000 (principal tiers, **not** loan products).

## NPL / delinquency — source `lakehouse.gold.loan_delinquency`

| # | Tile | Definition | Formula |
|---|---|---|---|
| N1 | NPL rate | Share of outstanding balance that is 90+ days past due | `npl_outstanding / total_outstanding`, carried on every mart row |
| N2 | Loans 90+ DPD | Count of disbursed loans in the 90+ bucket | `SUM(loan_count) WHERE bucket='90+'` |
| N3 | 90+ exposure | Outstanding balance in the 90+ bucket | `SUM(outstanding_balance) WHERE bucket='90+'` |
| N4 | Delinquency buckets | Count, balance and share per DPD bucket | window `SUM() OVER ()` for shares |
| N5 | Outstanding by bucket | Balance by bucket, severity-ordered | — |
| N6 | Loans by bucket | Count by bucket, severity-ordered | — |
| N7 | Overdue instalments by due month | **Proxy trend, not NPL history** — scheduled amount still `overdue` per contractual due month | `SUM(principal_due+interest_due) FILTER (WHERE status='overdue')` |

**DPD definition:** `as_of_date − MIN(due_date)` over the loan's `overdue` instalments,
floored at 0. A loan with no overdue instalment is `current`. This uses the real
repayment schedule, not a 365-day term assumption.
**Buckets:** `current` (<30) · `30-59` · `60-89` · `90+` (= NPL). There is no
`charge-off` bucket: the source has no write-off event. Any doc that lists
`90-179`/`charge-off` is stale (see README §6).
**NPL rate is based on principal outstanding**, not on the number of loans.

## Payments — sources `lakehouse.gold.loan_event_daily` (cash) + `lakehouse.silver.repayment_schedule` (contract)

| # | Tile | Definition | Basis |
|---|---|---|---|
| Y1 | Total collected | Every payment event ever recorded | cash |
| Y2 | Total disbursed | Every disbursement event ever recorded | cash |
| Y3 | Overdue amount | Principal+interest of instalments currently `overdue` | schedule |
| Y4 | Collection rate (due-to-date) | `paid / (paid + overdue)` amount — excludes not-yet-due instalments | schedule |
| Y5 | Instalments by status | Count and amount by `paid`/`overdue`/`scheduled` | schedule |
| Y6 | Instalment rollforward by due month | Per month: counts and amounts by status + `paid_share` | schedule |
| Y7 | Paid vs overdue by due month | Two-series bar of Y6's amounts | schedule |
| Y8 | Collections by day | Payment amount per calendar day (UTC) | cash |
| Y9 | Disbursement vs collection by day | Both daily series | cash |
| Y10 | Net cash flow by day | `payment_amount − disbursement_amount` (negative = net lending) | cash |

**Do not mix bases in one tile.** Cash = money moved (`loan_event`). Schedule = money
owed by instalment (`repayment_schedule.status`, maintained upstream by the LMS).
A cash figure and a schedule figure will never reconcile exactly — payments are not
allocated to individual instalments in this source.

## Data quality — source `lakehouse.quarantine_lms.quarantine_lms`

| # | Tile | Definition |
|---|---|---|
| D1 | Quarantined rows | Row-events in the DQ log across **all** dbt runs |
| D2 | Distinct rules triggered | How many different rules have rejected at least one row |
| D3 | Latest quarantine timestamp | Last time DQ isolated a row (stale ⇒ DQ hooks did not fire) |
| D4 | Runs in log | Distinct `run_id`s that wrote quarantine rows |
| D5 | Quarantined rows by rule | Row-events per rule id, all runs |
| D6 | By layer and target table | `bronze`/`silver`/`gold` × model, with last timestamp |
| D7 | By run (latest 20) | Per dbt invocation, with `source` = `batch`/`cdc` |
| D8 | Rules tripped in latest run | Current-run picture only — the panel to watch during a dirty scenario |

**Grain caveat:** the log is append-only, so D1/D5 are *row-events*, not a live
inventory of bad rows. D8 is the current-run view. Bad rows never enter a KPI —
they land here instead, which is the point of the panel.
