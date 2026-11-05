# Business dashboard — LMS POC gold layer

**Question this dashboard answers, at a glance:**
*"Is the loan book healthy — how much is outstanding, how much is going bad, are we
collecting, and how much bad data is being kept out of these numbers?"*

**Audience:** Randy (POC demo / exec read) · Atlas (data-lead review) · Keystone (pipeline).

**Status:** SQL, metric definitions and the provisioner are complete and written against
the dbt models in `dbt/models`. The dashboard is **not yet live in Metabase** — the worker
that produced this pack had no shell and no HTTP-write capability (see §5). One command
(§3) finishes it.

---

## 1. What is in here

| File | Purpose |
|---|---|
| `sql/01-portfolio.sql` | 10 cards — portfolio health (`gold.loan_portfolio_summary`) |
| `sql/02-npl.sql` | 7 cards — NPL / delinquency (`gold.loan_delinquency`) |
| `sql/03-payments.sql` | 10 cards — payments & collections (`gold.loan_event_daily`, `silver.repayment_schedule`) |
| `sql/04-data-quality.sql` | 8 cards — quarantine (`quarantine_lms.quarantine_lms`) |
| `metric_definitions.md` | One definition line per tile — the answer to "what does this mean" |
| `provision_metabase.py` | Creates/updates every card + the dashboard layout, then verifies row counts |

**35 cards, 4 panel groups, one dashboard:** `LMS POC — Business Performance (Gold)`

Each card carries its own header line with display type, grid size and axis mapping:

```
-- === card: Portfolio · Outstanding balance | display: scalar | size: 6x3 | fmt: outstanding_balance=currency ===
```

The header is machine-readable (the provisioner parses it) *and* human-readable, so the
SQL files double as the review artifact for Atlas.

## 2. Data contract — every panel is a real query

| Panel group | Table | dbt model |
|---|---|---|
| Portfolio health | `lakehouse.gold.loan_portfolio_summary` | `models/gold/loan_portfolio_summary.sql` |
| Book by currency (1 card) | `lakehouse.silver.loan` | `models/silver/loan.sql` |
| NPL / delinquency | `lakehouse.gold.loan_delinquency` | `models/gold/loan_delinquency.sql` |
| Payments — cash | `lakehouse.gold.loan_event_daily` | `models/gold/loan_event_daily.sql` |
| Payments — schedule | `lakehouse.silver.repayment_schedule` | `models/silver/repayment_schedule.sql` |
| Data quality | `lakehouse.quarantine_lms.quarantine_lms` | `models/quarantine.sql` |

No literals, no `VALUES` fallbacks, no hardcoded numbers. A card that cannot get real
data returns an error or zero rows and the provisioner fails (§4) — it never renders a
plausible-looking placeholder.

## 3. Provision it (one command)

The Metabase admin account already exists (`has-user-setup: true` on
`https://bi.onendo.cloud`), created in the UI — its password is not in the repo.

```bash
cd bi/metabase/dashboard
export METABASE_USER='<admin email>'
export METABASE_PASSWORD='<admin password>'      # never commit this

python3 provision_metabase.py --dry-run          # 1. parse + print the plan, no writes
python3 provision_metabase.py                    # 2. create cards + dashboard, then verify
```

* Python 3 stdlib only — no pip install, no jq.
* Idempotent: cards are matched by exact name and updated in place; the dashboard layout
  is re-applied wholesale. Re-running never duplicates anything.
* It does **not** create the Trino connection unless you pass `--create-db` (that stays an
  operator decision, per `docs/04-metabase.md` §3). If `Lakehouse` is missing it stops and
  says so.
* It never deletes a card or a dashboard.

Expected output tail:

```
[verify] all 35 cards returned real, non-empty data
[done] dashboard: https://bi.onendo.cloud/dashboard/<id>
```

Exit codes: `0` all good · `1` provisioning/SQL error · `2` a card returned zero rows ·
`3` dry run.

### Manual fallback (no API access)

Per `docs/04-metabase.md` §7 the repo has no Metabase automation; the UI path still works:
New → Question → Native query → `Lakehouse` → paste a card body from `sql/*.sql` → set
Display per the header → Save → add to dashboard `LMS POC — Business Performance (Gold)`.
The header's `fmt:` values map to Metabase column formatting (currency/percent).

## 4. The acceptance check is executable

`provision_metabase.py` runs every card through `POST /api/card/{id}/query` and prints a
row count per card, flagging `EMPTY` and `ERR`. "All panels returning non-empty real data"
is therefore a test result, not a claim. Re-run after any `dbt run` or data injection:

```bash
python3 provision_metabase.py && echo "dashboard still healthy"
```

## 5. Why this pack is delivered instead of a live dashboard

The kanban worker profile `prism` runs with a restricted toolset: file read/write,
`web_search`, kanban tools — **no shell, no code execution, no HTTP client**. Verified
during this task:

* `execute_code` → blocked by policy (`approvals.single_query_mode` denies unattended runs).
* no `terminal` tool in the platform toolset.
* `web_extract` backend is `ddgs` (search-only) → cannot fetch URLs.
* `kanban_attach_url` (server-side GET) confirmed the instance is up:
  `GET https://bi.onendo.cloud/api/health` → `{"status":"ok"}` and
  `GET /api/session/properties` → `has-user-setup: true`, `report-timezone: GMT`.
  That is read-only; creating cards/dashboards is POST/PUT.

So the split is: **this pack = all the work that does not need credentials; §3 = the one
step that does.** For Prism to own dashboards end-to-end, give the `prism` kanban worker
the `terminal` + `code_execution` toolsets (or an HTTP/`connections` tool) and the
Metabase admin credential via the profile env.

## 6. Known gaps — flagged, not papered over

| Gap | Impact | Owner |
|---|---|---|
| **NPL trend over time is not obtainable.** `gold.loan_delinquency` is a point-in-time snapshot (bucket rows, no date key). | The directive asks for "npl_rate trend over time"; only a snapshot exists. Card N7 is a labelled *proxy* (overdue amount by contractual due month), not a history of NPL rate. | **Keystone** — add `gold.loan_delinquency_snapshot` (`as_of_date` + bucket rows, insert-only per run) so the trend is real |
| **No currency dimension in gold.** `loan_portfolio_summary` sums USD/EUR/GBP/JPY/CAD/AUD with no FX conversion. | Every monetary KPI is a nominal multi-currency sum. Card P10 (`silver.loan`) makes the exposure visible. | **Keystone** — FX source + `currency` in the gold grain, or a `usd_equivalent` column |
| **No `charge-off` / write-off concept in the source.** | Buckets stop at `90+`; there is no formal NPL→loss transition. | **Keystone** (source model) |
| **`bi/metabase/delinquency_buckets.sql` is stale** — it expects buckets `90-179` and `charge-off`, which the current mart does not emit (it emits `current/30-59/60-89/90+`). | Pasting it gives 3 rows and silently wrong ordering. Superseded by `sql/02-npl.sql` card N4. | **Prism** — replace on next commit (left untouched here to keep this change additive) |
| **`90+` bucket is currently empty** in the last verified load (3 rows: current/30-59/60-89). | N1/N2/N3 read 0 — real, not broken. Populate with `POST /scenarios/loan-book` on the LMS, then `dbt run`. | Randy/Atlas (data injection is their call) |
| **Quarantine panel is empty on a perfectly clean run** by design. | D5–D8 can return zero rows after a clean load. Last verified load isolated ~19.6k rows (132,675 → 113,092 clean), so the log has real rows today. | — (working as intended) |

## 7. Refresh model

Cards are native queries with caching off (`MB_ENABLE_QUERY_CACHING=false`), so each view
re-queries Trino — the dashboard always reflects the last `dbt run`. No scheduled Metabase
subscription is configured (no SMTP in the stack). "Data as of" (card P1) is the freshness
signal, on the dashboard itself.
