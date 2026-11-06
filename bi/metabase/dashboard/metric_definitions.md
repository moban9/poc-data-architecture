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

---

## Money units — read this before quoting any money figure

The book spans **six currencies** (USD, EUR, GBP, JPY, CAD, AUD) and the gold layer
has **no FX conversion** (deliberate decision, option (a) in
`dbt/models/gold/loan_portfolio_summary.sql`). Therefore:

| Where | Unit | Rule |
|---|---|---|
| Portfolio money tiles (P2, P4, P6, P8, P9, P10) | **nominal, per currency** | Each row/bar is one ISO-4217 currency. Sliced by `currency`, so every number is a real amount in its own unit. **Do not add two rows together.** |
| Portfolio count tiles (P3, P5, P7) | loans | Currency-agnostic — these are real totals. |
| NPL balances (N3, N5, N8, N9 `outstanding_balance`) | **nominal, all currencies mixed** | The snapshot grain is `(as_of_date, delinquency_bucket)` with no currency column, so this balance cannot be sliced. Labelled nominal in the tile text. |
| NPL rates (N1, N7, `npl_rate`) | ratio 0..1 | `90+ outstanding / total outstanding`. A ratio of two nominal totals — dimensionless, and the currency mix is stable enough that it reads as a real rate. |
| Payments money, aggregated tiles (Y1, Y2, Y3, Y5, Y6, Y7) | **nominal, per currency** | Grain is now `(event_date, currency)` in gold and `currency` is denormalized onto the schedule (Keystone t_8cbf9a27), so each bar/row is one ISO-4217 currency. Same rule as portfolio money: **do not add two rows together.** |
| Payments money, daily series (Y8, Y10) | **nominal, per currency** | One series per currency (conditional aggregates over the six accepted codes). The axis is shared and nominal — read each series against itself over time, never one currency against another. |
| Payments money, daily detail (Y9) | **nominal, per currency** | Unpivoted `(event_date, currency)` table; every code is printed with its own unit per row. |
| Payments ratios (Y4 `collection_rate`, Y6 `paid_share`) | ratio 0..1 | Dimensionless, so unaffected by currency. Y4 pools currencies by design (ratio of two nominal sums); Y6 `paid_share` is computed within each month **and** currency. |

**There is deliberately no single cross-currency headline money number on this
dashboard.** Summing six currencies without a rate would be a fabricated figure; the
per-currency split (P2/P4, detailed in P10) is the honest headline for the book, and
Y1/Y2/Y3/Y7 are its equivalent for cash and schedule. The only money figures that
still pool currencies are the NPL balances (N3, N5, N8) — and those are labelled
nominal on the tile because the snapshot grain has no currency column.

**Derived dimensions (there is no status/product column in the LMS source):**
- `loan_status`: `originated` = origination event, no disbursement · `disbursed` = funded, no payment · `repaying` = funded and ≥1 payment.
- `loan_type`: `micro` < 25,000 · `small` 25,000–49,999 · `medium` 50,000–74,999 · `large` ≥ 75,000 (principal tiers, **not** loan products).

## Portfolio health — source `lakehouse.gold.loan_portfolio_summary`

Grain: `(loan_status, loan_type, currency)`.

| # | Tile | Definition | Formula |
|---|---|---|---|
| P1 | Data as of | Latest event timestamp in the lakehouse = the dataset's "now" | `MAX(occurred_at)::date` over `silver.loan_event` |
| P2 | Outstanding balance **by currency** | Principal still owed, floored at 0 per loan, per currency | `SUM(outstanding_balance) GROUP BY currency`; mart computes `GREATEST(principal - payments, 0)` |
| P3 | Loans in book | Loans that passed Silver DQ, all statuses, all currencies | `SUM(loan_count)` |
| P4 | Principal originated **by currency** | Gross principal written, not net of repayments, per currency | `SUM(total_principal) GROUP BY currency` |
| P5 | Loans by status | Count split by derived lifecycle status | `SUM(loan_count) GROUP BY loan_status` |
| P6 | Outstanding by status | Money still owed, split by status **and currency** so each row has one unit | `SUM(outstanding_balance) GROUP BY loan_status, currency` |
| P7 | Loans by tier | Count split by derived principal-size tier | `SUM(loan_count) GROUP BY loan_type` |
| P8 | Avg loan size by tier | Principal per loan within tier **and currency** (not mean of means) | `SUM(total_principal)/SUM(loan_count) GROUP BY loan_type, currency` |
| P9 | Status × tier detail | The mart at native grain, currency included | one row per (`loan_status`,`loan_type`,`currency`) |
| P10 | Book by currency | Currency split of counts, principal, outstanding, avg size and principal share — **from gold** | `SUM(total_principal)/SUM(SUM(total_principal)) OVER ()` for `share_of_principal` |

P10 replaced the old `silver.loan` card: gold now carries `currency`, so the panel
reads the same mart as every other portfolio tile (no second source, no drift).

## NPL / delinquency — sources `lakehouse.gold.loan_delinquency` (current) + `lakehouse.gold.loan_delinquency_snapshot` (history)

| # | Tile | Definition | Formula |
|---|---|---|---|
| N1 | NPL rate | Share of outstanding that is 90+ DPD, current snapshot | `MAX(npl_rate)` over `gold.loan_delinquency` |
| N2 | Loans 90+ DPD | Disbursed loans in the 90+ bucket | `SUM(loan_count) WHERE bucket='90+'` |
| N3 | 90+ exposure | Outstanding in the 90+ bucket (nominal, all currencies) | `SUM(outstanding_balance) WHERE bucket='90+'` |
| N4 | Delinquency buckets | Count, balance and share per DPD bucket | window `SUM() OVER ()` for shares |
| N5 | Outstanding by bucket | Balance by bucket, severity-ordered (nominal, all currencies) | — |
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
carries `currency` denormalized from the parent loan. Every money tile below is sliced
by currency — there is no mixed-currency sum left in this pack.

| # | Tile | Definition | Basis | Currency dimension |
|---|---|---|---|---|
| Y1 | Total collected | Every payment event ever recorded, per currency | cash | one bar per `currency` |
| Y2 | Total disbursed | Every disbursement event ever recorded, per currency | cash | one bar per `currency` |
| Y3 | Overdue amount | Principal+interest of instalments currently `overdue`, per currency | schedule | one bar per `currency` |
| Y4 | Collection rate (due-to-date) | `paid / (paid + overdue)` amount — excludes not-yet-due instalments | schedule | **none** — dimensionless ratio; pools currencies by design |
| Y5 | Instalments by status | Count and amount by `paid`/`overdue`/`scheduled` | schedule | one row per (`currency`, `status`) |
| Y6 | Instalment rollforward by due month | Per (month, currency): counts and amounts by status + `paid_share` | schedule | one row per (`due_month`, `currency`); `paid_share` computed within that currency |
| Y7 | Paid vs overdue by currency | Two-series bar of the paid vs overdue amounts, all due months | schedule | x-axis = `currency` |
| Y8 | Collections by day | Payment amount per calendar day (UTC) | cash | one series per currency |
| Y9 | Disbursement vs collection by day | Both daily series at `(event_date, currency)`, plus net | cash | one row per (`event_date`, `currency`), unpivoted |
| Y10 | Net cash flow by day | `payment_amount − disbursement_amount` (negative = net lending) | cash | one series per currency |

**Do not mix bases in one tile.** Cash = money moved (`loan_event`). Schedule = money
owed by instalment (`repayment_schedule.status`, maintained upstream by the LMS).
A cash figure and a schedule figure will never reconcile exactly — payments are not
allocated to individual instalments in this source.

**Currency rule (gap CLOSED — Keystone t_8cbf9a27).** Every money tile is sliced by
`currency`, mirroring the portfolio pack (P2/P4/P6/P8/P9). No FX conversion exists, by
decision: each bar, row and series is a **nominal** amount in its own ISO-4217 unit, so
two currencies are never added together and never compared on a chart axis. The ratio
tiles (Y4, `paid_share`) are the only tiles allowed to collapse the currency dimension,
because a ratio is dimensionless.

**Y7 changed axis.** It used to be "paid vs overdue by due month". Month × currency
would need 12 series (2 metrics × 6 currencies) on one axis, which cannot be read, and
collapsing those series to a month total would be the mixed-currency sum this pack
forbids. Month detail — with currency — is **Y6** (table); Y7 now compares currencies
across all due months. The old card is orphaned in the collection (README §6).

**Pivot coupling for Y8/Y10.** The per-currency series are conditional aggregates over
the six codes the LMS accepts (`src/lms/constants.py` `VALID_CURRENCIES`, enforced by the
dbt `accepted_values` tests): USD, EUR, GBP, JPY, CAD, AUD. Trino has no dynamic `PIVOT`
and the provisioner allows one graph dimension per card, so the list is written out. If
that list changes, update Y8/Y10 in the same commit — Y9 is unpivoted and will still
print every code, and the Y1/Y2 bars are the coverage check.

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
