# Business dashboard — LMS POC gold layer

**Question this dashboard answers, at a glance:**
*"Is the loan book healthy — how much is outstanding, how much is going bad, is that
getting better or worse, are we collecting, and how much bad data is being kept out
of these numbers?"*

**Audience:** Randy (POC demo / exec read) · Atlas (data-lead review) · Keystone (pipeline).

**Status:** **live** — dashboard id **3**, `LMS POC — Business Performance (Gold)`, at
<https://bi.onendo.cloud/dashboard/3>. 37 cards across 4 panel groups, every card a
native Trino query against the gold/silver layer. Last full verification:
`provision_metabase.py` exit 0, *"all cards returned real, non-empty data"*.
This revision re-points three panels at the extended gold contract (NPL snapshot history,
`currency` in the portfolio grain, and `currency` through the payments pack) — re-run §3
to publish it.

---

## 1. What is in here

| File | Purpose |
|---|---|
| `sql/01-portfolio.sql` | 10 cards — portfolio health (`gold.loan_portfolio_summary`, per currency) |
| `sql/02-npl.sql` | 9 cards — NPL / delinquency, incl. the real snapshot trend (`gold.loan_delinquency`, `gold.loan_delinquency_snapshot`) |
| `sql/03-payments.sql` | 10 cards — payments & collections, money tiles sliced by `currency` (`gold.loan_event_daily`, `silver.repayment_schedule`) |
| `sql/04-data-quality.sql` | 8 cards — quarantine (`quarantine_lms.quarantine_lms`) |
| `metric_definitions.md` | One definition line per tile + the money-unit rules |
| `provision_metabase.py` | Creates/updates every card + the dashboard layout, then verifies row counts |

Each card carries its own header line with display type, grid size and axis mapping:

```
-- === card: Portfolio · Outstanding balance by currency | display: bar | size: 12x5 | x: currency | y: outstanding_balance | fmt: outstanding_balance=currency ===
```

The header is machine-readable (the provisioner parses it) *and* human-readable, so the
SQL files double as the review artifact for Atlas.

## 2. Data contract — every panel is a real query

| Panel group | Table | dbt model |
|---|---|---|
| Portfolio health (P1–P10) | `lakehouse.gold.loan_portfolio_summary` — grain `(loan_status, loan_type, currency)` | `models/gold/loan_portfolio_summary.sql` |
| NPL — current snapshot (N1–N6) | `lakehouse.gold.loan_delinquency` | `models/gold/loan_delinquency.sql` |
| NPL — trend / history (N7–N9) | `lakehouse.gold.loan_delinquency_snapshot` — append-only, grain `(as_of_date, delinquency_bucket)` | `models/gold/loan_delinquency_snapshot.sql` |
| Payments — cash | `lakehouse.gold.loan_event_daily` — grain `(event_date, currency)` | `models/gold/loan_event_daily.sql` |
| Payments — schedule | `lakehouse.silver.repayment_schedule` — `currency` denormalized from the parent loan | `models/silver/repayment_schedule.sql` |
| Data quality | `lakehouse.quarantine_lms.quarantine_lms` | `models/quarantine.sql` |

No literals, no `VALUES` fallbacks, no hardcoded numbers. A card that cannot get real
data returns an error or zero rows and the provisioner fails (§4) — it never renders a
plausible-looking placeholder.

### Money is per currency — by design

`loan_portfolio_summary` carries `currency` and its money columns are **nominal per
currency**; there is no FX conversion (option (a), documented in the model header).
The book spans six currencies, so a cross-currency `SUM` is not a real number:

* portfolio money tiles (P2, P4, P6, P8, P9, P10) are all **sliced by `currency`**;
* portfolio count tiles (P3, P5, P7) are currency-agnostic and total safely;
* **payments money tiles are sliced the same way** (Y1, Y2, Y3, Y5, Y6, Y7 as bars/rows,
  Y8/Y10 as one series per currency, Y9 as an `(event_date, currency)` table) — the
  currency gap that used to make this pack a nominal multi-currency sum is closed;
* payments ratios (Y4, Y6 `paid_share`) are dimensionless and unaffected;
* there is **no single cross-currency headline money number** on the dashboard — the
  per-currency split *is* the headline.

NPL balances (N3, N5, N8) stay nominal/unsliced because the snapshot grain has no
currency column; the `npl_rate` ratio is dimensionless and unaffected. Full rules:
`metric_definitions.md` § *Money units*.

## 3. Provision it (one command)

```bash
cd bi/metabase/dashboard
export METABASE_USER='<admin email>'
export METABASE_PASSWORD='<admin password>'      # never commit this

python3 provision_metabase.py --database-name 'Lakehouse (Trino)' --dry-run   # 1. plan only
python3 provision_metabase.py --database-name 'Lakehouse (Trino)'             # 2. create + verify
```

* **The connection is named `Lakehouse (Trino)`** (Metabase db id=2), not `Lakehouse` —
  pass `--database-name` or the run stops at `[db] no Metabase database named …`.
* Python 3 stdlib only — no pip install, no jq.
* Idempotent: cards are matched by exact name and updated in place; the dashboard layout
  is re-applied wholesale. Re-running never duplicates anything.
* It does **not** create the Trino connection unless you pass `--create-db`.
* It never deletes a card or a dashboard.
* Trailing `;` is stripped per card — Trino's JDBC path rejects it.

Expected output tail:

```
[verify] all 37 cards returned real, non-empty data
[done] dashboard: https://bi.onendo.cloud/dashboard/3
```

Exit codes: `0` all good · `1` provisioning/SQL error · `2` a card returned zero rows ·
`3` dry run.

### Who runs it

The `prism` kanban worker has no shell, no code execution and no HTTP client (see §5),
so a *Prism* card can author and review the pack but cannot POST it. Runs are executed
by the operator profile (`default`) which holds the Metabase admin session and the
shell. Everything the run needs is in this directory — no manual card building.

### Manual fallback (no API access)

Metabase UI: New → Question → Native query → `Lakehouse (Trino)` → paste a card body
from `sql/*.sql` → set Display per the header → Save → add to dashboard
`LMS POC — Business Performance (Gold)`. The header's `fmt:` values map to Metabase
column formatting (currency/percent). Card names must match the header exactly, or the
next provisioner run creates a second card instead of updating this one.

## 4. The acceptance check is executable

`provision_metabase.py` runs every card through `POST /api/card/{id}/query` and prints a
row count per card, flagging `EMPTY` and `ERR`. "All panels returning non-empty real
data" is therefore a test result, not a claim. Re-run after any `dbt run`:

```bash
python3 provision_metabase.py --database-name 'Lakehouse (Trino)' && echo "dashboard still healthy"
```

## 5. Why Prism's worker cannot publish, and what that means for review

The `prism` kanban worker runs with a restricted toolset: file read/write, `web_search`,
kanban tools — **no shell, no code execution, no HTTP client**. Verified again on this
task:

* `execute_code` → blocked by policy (`approvals.single_query_mode` denies unattended runs).
* no `terminal` tool in the kanban platform toolset.
* `web_extract` backend is `ddgs` (search-only) → cannot fetch or POST.
* the Metabase admin credential is not in the repo (created in the UI, per `docs/04-metabase.md` §3).

So the split is: **Prism authors + reviews the pack and its numbers; the operator runs
§3 and pastes the verify table back on the card.** A Prism card is only "done" when that
verify output shows every card PASS.

## 6. Known gaps — flagged, not papered over

| Gap | Impact | Owner / status |
|---|---|---|
| ~~**NPL trend over time is not obtainable**~~ | **CLOSED.** `gold.loan_delinquency_snapshot` is append-only over `(as_of_date, delinquency_bucket)`; N7/N8/N9 read it. | Keystone t_51346c5a · **resolved** |
| ~~**No currency dimension in gold**~~ | **CLOSED.** `loan_portfolio_summary` grain is `(loan_status, loan_type, currency)`; portfolio money tiles are per-currency and P10 reads gold. No FX conversion exists — by decision, not omission. | Keystone t_51346c5a · **resolved** |
| **NPL snapshot history is short (2 dates: 2026-12-05, 2026-12-06).** | N7 is a 2-point line; it is a real series but not yet a trend you can read a direction from. It grows one date per distinct dataset "now". | Working as designed — no backfill, ever |
| ~~**Payments money is still a nominal multi-currency sum**~~ | **CLOSED.** `gold.loan_event_daily` grain is `(event_date, currency)` and `silver.repayment_schedule` carries `currency`; Y1, Y2, Y3, Y5–Y10 are now currency-sliced (bars/rows, one series per currency, or an unpivoted `(event_date, currency)` table). Ratios (Y4, `paid_share`) were always dimensionless. No FX conversion exists — by decision, not omission. | Keystone t_8cbf9a27 (materialized by Piston t_b9c989e7) · **resolved** |
| **NPL balances are nominal across currencies** (N3, N5, N8). The snapshot grain has no currency column. | Balances in the NPL pack are labelled nominal and must not be added to a portfolio figure. Rates are unaffected. | Deliberate scope of t_51346c5a · Keystone if a currency-sliced NPL balance is needed |
| **No `charge-off` / write-off concept in the source.** | Buckets stop at `90+`; there is no NPL→loss transition, so no charge-off panel. Adding a bucket before the source emits write-off events would be fabrication. | Keystone (source model) — **out of scope until `src/lms` grows the event** |
| **Orphan cards in the Metabase collection.** Four cards created by earlier revisions are no longer on the dashboard: *"Portfolio · Outstanding balance"* and *"Portfolio · Principal originated"* (the old mixed-currency scalars, replaced by their per-currency versions), *"NPL · Overdue instalments by due month (proxy trend)"* (superseded by N7 + payments Y6) and *"Payments · Paid vs overdue by due month"* (replaced by *"Paid vs overdue by currency"* — a month × currency bar would need 12 series; month detail is Y6). | Cosmetic clutter in the collection only; nothing on the dashboard reads them. Archiving/deleting needs Randy's approval (Prism never deletes reports). | Randy — approve archive |
| **`90+` bucket may read 0** on a load where nothing is 90+ DPD. | N1/N2/N3 then read 0 — real, not broken. Populate with `POST /scenarios/loan-book` on the LMS, then `dbt run`. | Randy/Atlas (data injection is their call) |
| **Quarantine panel is empty on a perfectly clean run** by design. | D5–D8 can return zero rows after a clean load. The provisioner would flag it; that is expected behaviour, not a regression. | — (working as intended) |

**Superseded files:** `bi/metabase/delinquency_buckets.sql` and
`bi/metabase/npl_rate_kpi.sql` expected buckets `90-179`/`charge-off` that the mart has
never emitted. They are now deprecation stubs pointing here — see `bi/metabase/README.md`.

## 7. Refresh model

Cards are native queries with caching off (`MB_ENABLE_QUERY_CACHING=false`), so each view
re-queries Trino — the dashboard always reflects the last `dbt run`. No scheduled Metabase
subscription is configured (no SMTP in the stack). "Data as of" (P1) is the freshness
signal, on the dashboard itself; the snapshot cards (N7–N9) additionally show which dates
the pipeline has captured.
