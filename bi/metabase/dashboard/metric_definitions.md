# Metric definitions — LMS POC dashboards

One line per tile. If a number on the dashboard is questioned, this file answers it
without opening dbt. Every metric below is computed by a real query in `sql/*.sql`
against the gold/silver layer — nothing is typed in by hand.

**Dashboards (two since the split):** `LMS POC — Business Performance` (P*, N*, Y* cards)
and `LMS POC — Data Quality` (D* cards) · **Owner:** Prism (BI) ·
**Audience:** Randy (POC demo / exec read) · Atlas (data-lead review) · Keystone (pipeline owner).
Business tiles and DQ tiles are deliberately on separate boards: a quarantine count is a
pipeline diagnostic, not a business KPI, and the two are never added together.

**As-of:** all gold marts are point-in-time builds. "Now" for the dataset is
`MAX(silver.loan_event.occurred_at)`, shown on the dashboard as **Data as of**.
Re-running `dbt run` after the LMS scenario endpoint `POST /scenarios/loan-book`
moves that date and every number with it. The NPL snapshot history (N7–N9) records
one date per distinct "now" it has been built on.

**Currency:** the POC book is **single-currency (IDR)**. Money tiles are single
aggregated totals across the whole book — there is no per-currency slice anywhere on
the dashboard (task t_d2573cb4 reverted the earlier currency-sliced version).

---

## Money units — read this before quoting any money figure

**The POC book is single-currency: IDR.** Every money tile sums across the whole book
and prints **one real total**; no card groups by `currency`.

| Where | Unit | Rule |
|---|---|---|
| Portfolio money (P2 outstanding, P4 principal, P6 by status, P8 avg size, P9 status × tier) | **IDR, nominal** | `SUM(...)` across the book — no `GROUP BY currency`. |
| Portfolio count tiles (P3, P5, P7) | loans | Currency-agnostic by construction. |
| Payments money (Y1 collected, Y2 disbursed, Y3 overdue, Y5 by status, Y6 by month, Y7 by month, Y8/Y10 daily series, Y9 daily detail) | **IDR, nominal** | `SUM(...)` across the book — no `GROUP BY currency`. |
| Payments ratios (Y4 `collection_rate`, Y6 `paid_share`) | ratio 0..1 | Dimensionless; unaffected by the currency question. |
| NPL balances (N3, N5, N8, N9 `outstanding_balance`) | **IDR, nominal** | The snapshot grain is `(as_of_date, delinquency_bucket)` with no currency column. |
| NPL rates (N1, N7, `npl_rate`) | ratio 0..1 | `90+ outstanding / total outstanding` — dimensionless. |

**The guard is a card, not a comment.** P10 *"Portfolio · Currency codes in book (must
be 1)"* = `COUNT(DISTINCT currency)` over `gold.loan_portfolio_summary`:

* **1** → the mart is single-currency and every total above is a real total;
* **> 1** → the mart carries more than one nominal currency, so the aggregated money
  tiles are mixed-currency sums with no FX conversion behind them. Re-slice them (or
  filter to one code) before quoting a number.

Do not delete P10 while the mart still has a `currency` column. It replaced the old
"Book by currency" panel: with one currency there is no split to draw, but the
invariant still has to be visible on the dashboard.

**Formatting note.** `fmt: …=currency` in a card header selects Metabase's *number
style*, which is **not** a currency converter — the symbol comes from the Metabase
instance setting (Admin → Localization → Currency). Set that to **IDR** so money tiles
do not render with a `$` sign.

**Data-side status (open, owner Keystone).** The gold marts still expose a `currency`
column and the LMS generator still draws from six codes
(`src/lms/constants.py` `VALID_CURRENCIES` = USD, EUR, GBP, JPY, CAD, AUD). Until that
list is IDR-only and the marts are rebuilt (`POST /scenarios/loan-book` + `dbt run`),
P10 will read **> 1** and the aggregated money tiles are nominal across those codes.
The dashboard shows that state honestly rather than hiding it — the BI revert is done,
the data change is not.

**Derived dimensions (there is no status/product column in the LMS source):**
- `loan_status`: `originated` = origination event, no disbursement · `disbursed` = funded, no payment · `repaying` = funded and ≥1 payment.
- `loan_type`: `micro` < 25,000 · `small` 25,000–49,999 · `medium` 50,000–74,999 · `large` ≥ 75,000 (principal tiers, **not** loan products).

## Portfolio health — source `lakehouse.gold.loan_portfolio_summary`

Grain: `(loan_status, loan_type, currency)`. The mart is finer than the cards need — the
cards below deliberately **do not** group by `currency`.

| # | Tile | Definition | Formula |
|---|---|---|---|
| P1 | Data as of | Latest event timestamp in the lakehouse = the dataset's "now" | `MAX(occurred_at)::date` over `silver.loan_event` |
| P2 | Outstanding balance | Principal still owed across the whole book, floored at 0 per loan | `ROUND(SUM(outstanding_balance),2)`; mart computes `GREATEST(principal - payments, 0)` |
| P3 | Loans in book | Loans that passed Silver DQ, all statuses | `SUM(loan_count)` |
| P4 | Principal originated | Gross principal written across the book, not net of repayments | `ROUND(SUM(total_principal),2)` |
| P5 | Loans by status | Count split by derived lifecycle status | `SUM(loan_count) GROUP BY loan_status` |
| P6 | Outstanding by status | Money still owed per status — one total per status, no currency split | `SUM(outstanding_balance) GROUP BY loan_status` |
| P7 | Loans by tier | Count split by derived principal-size tier | `SUM(loan_count) GROUP BY loan_type` |
| P8 | Avg loan size by tier | Principal per loan within the tier (not the mean of means) | `SUM(total_principal)/SUM(loan_count) GROUP BY loan_type` |
| P9 | Status × tier detail | The mart at reporting grain, one row per (status, tier) | `GROUP BY loan_status, loan_type` |
| P10 | **Currency codes in book (must be 1)** | Single-currency guard on P2/P4/P6/P8/P9 | `COUNT(DISTINCT currency)` over `gold.loan_portfolio_summary` |

P2 and P4 are scalars again (one number each) and reuse the card names of the pre-slice
version, so the earlier orphaned cards in the collection are updated in place rather than
duplicated. P10's predecessor *"Portfolio · Book by currency"* is now orphaned (README §6).

## NPL / delinquency — sources `lakehouse.gold.loan_delinquency` (current) + `lakehouse.gold.loan_delinquency_snapshot` (history)

| # | Tile | Definition | Formula |
|---|---|---|---|
| N1 | NPL rate | Share of outstanding that is 90+ DPD, current snapshot | `MAX(npl_rate)` over `gold.loan_delinquency` |
| N2 | Loans 90+ DPD | Disbursed loans in the 90+ bucket | `SUM(loan_count) WHERE bucket='90+'` |
| N3 | 90+ exposure | Outstanding in the 90+ bucket (nominal, IDR) | `SUM(outstanding_balance) WHERE bucket='90+'` |
| N4 | Delinquency buckets | Count, balance and share per DPD bucket | window `SUM() OVER ()` for shares |
| N5 | Outstanding by bucket | Balance by bucket, severity-ordered (nominal, IDR) | — |
| N6 | Loans by bucket | Count by bucket, severity-ordered | — |
| N7 | **NPL rate trend** | **Real** portfolio NPL rate per snapshot date | `MAX(npl_rate) GROUP BY as_of_date` over `gold.loan_delinquency_snapshot` |
| N8 | Outstanding by bucket over snapshot dates | Bucket mix per snapshot date (one series per bucket) | `SUM(...) FILTER/CASE GROUP BY as_of_date` |
| N9 | Snapshot history | The append-only snapshot at native grain — the audit view behind N7/N8 | `share_of_book = outstanding / SUM(outstanding) OVER (PARTITION BY as_of_date)` |

**N7 is a real series, not a proxy.** It replaced the old "overdue instalments by
contractual due month" card, which measured *when the book started slipping* by
scheduled due month and was never an NPL-rate history. That proxy is now superseded
by the payments pack (Y6 rollforward by due month) and is no longer on the dashboard.
N7 has one point per date the pipeline has actually run on; with 2 dates it is a
2-point line. Do not add trend language ("improving/worsening") until it has enough
real points — and never backfill or smooth it.

**DPD definition:** `as_of_date − MIN(due_date)` over the loan's `overdue` instalments,
floored at 0. A loan with no overdue instalment is `current`. This uses the real
repayment schedule, not a 365-day term assumption.
**Buckets:** `current` (<30) · `30-59` · `60-89` · `90+` (= NPL). There is no
`charge-off` bucket: the source has no write-off event, so an NPL→loss panel is
**out of scope until `src/lms` grows a write-off event**. Any doc that lists
`90-179`/`charge-off` is stale.
**NPL rate is based on principal outstanding**, not on the number of loans.

## Payments — sources `lakehouse.gold.loan_event_daily` (cash) + `lakehouse.silver.repayment_schedule` (contract)

Grain: `gold.loan_event_daily` is `(event_date, currency)`; `silver.repayment_schedule`
carries `currency` denormalized from the parent loan. Both are finer than the cards
need — **no payments card groups by `currency`** any more.

| # | Tile | Definition | Basis |
|---|---|---|---|
| Y1 | Total collected | Every payment event ever recorded, one total for the book | cash |
| Y2 | Total disbursed | Every disbursement event ever recorded, one total for the book | cash |
| Y3 | Overdue amount | Principal+interest of instalments currently `overdue` | schedule |
| Y4 | Collection rate (due-to-date) | `paid / (paid + overdue)` amount — excludes not-yet-due instalments | schedule |
| Y5 | Instalments by status | Count and amount by `paid`/`overdue`/`scheduled`, one row per status | schedule |
| Y6 | Instalment rollforward by due month | Per due month: counts and amounts by status + `paid_share` | schedule |
| Y7 | Paid vs overdue by due month | Two-series bar of the paid vs overdue amounts per contractual due month | schedule |
| Y8 | Collections by day | Payment amount per calendar day (UTC), one line | cash |
| Y9 | Disbursement vs collection by day | Both daily amounts plus net, one row per day | cash |
| Y10 | Net cash flow by day | `payment_amount − disbursement_amount` (negative = net lending), one line | cash |

**Do not mix bases in one tile.** Cash = money moved (`loan_event`). Schedule = money
owed by instalment (`repayment_schedule.status`, maintained upstream by the LMS).
A cash figure and a schedule figure will never reconcile exactly — payments are not
allocated to individual instalments in this source.

**Y7 changed back.** The currency-sliced version ("Paid vs overdue **by currency**")
existed only while the book was multi-currency; with one currency it carried a single
useless category. Y7 is again *paid vs overdue by contractual due month* — when the book
started slipping, and how much of each month's dues has been collected. Month detail
with counts and `paid_share` is Y6.

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
inventory of bad rows. D8 is the current-run view. Bad rows never enter a KPI — they
land here instead, which is the point of the panel.
