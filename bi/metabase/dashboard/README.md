# LMS POC dashboards — gold layer (business + data quality)

**Two dashboards, one question each.**

`LMS POC — Business Performance` — *"Is the loan book healthy — how much is outstanding,
how much is going bad, is that getting better or worse, and are we collecting?"*
29 cards: portfolio (P1–P10), NPL (N1–N9), payments (Y1–Y10).

`LMS POC — Data Quality` — *"What is the pipeline rejecting, how much of it, and by which
rule?"* 8 cards: quarantine (D1–D8).

**Why two:** quarantine counts are pipeline diagnostics, not business performance. Side by
side with the portfolio tiles they invited the reading *"N bad rows = N bad loans"*, and
they pushed the business headline tiles down the page. Randy asked for the separation, so
each board now serves exactly one audience and one question.

**Audience:** business board — Randy (POC demo / exec read) · Atlas (data-lead review).
DQ board — Keystone (pipeline owner) · Atlas (data-lead review) · Randy (ad hoc).

**Status:** **live** — business board is dashboard id **3**; the split renamed it in place
from `LMS POC — Business Performance (Gold)` to `LMS POC — Business Performance`, so
<https://bi.onendo.cloud/dashboard/3> still resolves. The DQ board is created by the same
run (new id, printed as `[done] LMS POC — Data Quality: …/dashboard/<id>`).
Every card is a native Trino query against the gold/silver layer.

---

## 1. What is in here

| File | Dashboard | Purpose |
|---|---|---|
| `sql/01-portfolio.sql` | Business Performance | 10 cards — portfolio health, **aggregated** money totals + the single-currency guard (`gold.loan_portfolio_summary`) |
| `sql/02-npl.sql` | Business Performance | 9 cards — NPL / delinquency, incl. the real snapshot trend (`gold.loan_delinquency`, `gold.loan_delinquency_snapshot`) |
| `sql/03-payments.sql` | Business Performance | 10 cards — payments & collections, **aggregated** money tiles, no currency split (`gold.loan_event_daily`, `silver.repayment_schedule`) |
| `sql/04-data-quality.sql` | **Data Quality** | 8 cards — quarantine (`quarantine_lms.quarantine_lms`) |
| `metric_definitions.md` | both | One definition line per tile + the money-unit rules |
| `provision_metabase.py` | both | Creates/updates every card, builds **two** dashboard layouts, prunes tiles that do not belong, then verifies row counts |

The dashboard each file belongs to is declared in `DASHBOARD_PACKS` at the top of
`provision_metabase.py` (`files` are file-stem prefixes). Moving a pack to another board is
a one-line edit there — or a `--dashboard-map '04-data-quality=…'` flag at run time; no SQL
changes.

Each card carries its own header line with display type, grid size and axis mapping:

```
-- === card: Portfolio · Outstanding balance | display: scalar | size: 6x3 | fmt: outstanding_balance=currency ===
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

### Money is single-currency — aggregated, with a guard

The POC book is **single-currency (IDR)** (Randy's call, task t_d2573cb4), so every money
tile is a **single aggregated total across the book**. No card groups by `currency`:

* portfolio money tiles (P2 outstanding, P4 principal, P6 by status, P8 avg size, P9
  status × tier) `SUM` across the mart; portfolio counts (P3, P5, P7) always did;
* payments money tiles (Y1, Y2, Y3, Y5, Y6, Y7, Y8, Y9, Y10) `SUM` across the book — the
  daily series are one line, not one line per currency;
* payments ratios (Y4 `collection_rate`, Y6 `paid_share`) are dimensionless;
* **P10 "Currency codes in book (must be 1)"** is the guard: `COUNT(DISTINCT currency)`
  over `gold.loan_portfolio_summary`. It reads 1 when the book is single-currency. If it
  ever reads > 1, every aggregated money tile is a mixed-currency nominal sum and must be
  re-sliced before it is quoted — the invariant lives on the board, not in someone's memory.

The mart still carries a `currency` column (gold grain `(loan_status, loan_type, currency)`;
`loan_event_daily` `(event_date, currency)`) and the LMS generator still lists six codes in
`src/lms/constants.py` `VALID_CURRENCIES`. Until that list is IDR-only and the marts are
rebuilt, P10 reads > 1 and the money tiles are nominal across those codes — visible on the
dashboard, not hidden. NPL balances (N3, N5, N8) were never currency-columned (snapshot
grain is `(as_of_date, delinquency_bucket)`). Full rules: `metric_definitions.md` § *Money units*.

## 3. Provision both dashboards (one command)

```bash
cd bi/metabase/dashboard
export METABASE_USER='<admin email>'
export METABASE_PASSWORD='<admin password>'      # never commit this

python3 provision_metabase.py --base-url https://bi.onendo.cloud \
    --database-name 'Lakehouse (Trino)' --dry-run        # 1. plan only (both boards)
python3 provision_metabase.py --base-url https://bi.onendo.cloud \
    --database-name 'Lakehouse (Trino)' --create-db      # 2. create + verify
```

* **The connection is named `Lakehouse (Trino)`** (Metabase db id=2), not `Lakehouse` —
  pass `--database-name` or the run stops at `[db] no Metabase database named …`.
  `--create-db` is a no-op when it already exists (kept so the command works on a fresh stack).
* One run builds **both** dashboards: cards are created/updated once, then each board gets
  its own layout. Nothing is provisioned twice.
* Python 3 stdlib only — no pip install, no jq.
* Idempotent: cards are matched by exact name and updated in place; each dashboard layout is
  re-applied wholesale. Re-running never duplicates a card or a dashboard.
* **Tiles are pruned, cards never are.** After applying a layout the script reads the
  dashboard back and deletes any dashcard that is not in that board's card set — that is
  what removes the 8 DQ tiles from the business board on the first split run — then fails
  loudly if the board's tile set is not exactly the pack's card set (`layout mismatch`).
* **This run is the currency revert (t_d2573cb4).** Counts do not change — 29 business /
  8 DQ / 37 total — so the acceptance output is the same shape as the split run. One card
  is **new** (*"Portfolio · Currency codes in book (must be 1)"*, the single-currency
  guard); every other card is updated in place, including the three pre-slice cards that
  had been orphaned (*"Portfolio · Outstanding balance"*, *"Portfolio · Principal
  originated"*, *"Payments · Paid vs overdue by due month"*), which the revert reuses. The
  four currency-sliced cards are left unattached in the collection (tiles are pruned,
  cards are not) — see §6.
* It does **not** create the Trino connection unless you pass `--create-db`.
* It never deletes a card or a dashboard.
* Trailing `;` is stripped per card — Trino's JDBC path rejects it.

Expected output (verify section is last and is the acceptance check):

```
[done] LMS POC — Business Performance: https://bi.onendo.cloud/dashboard/3
[done] LMS POC — Data Quality: https://bi.onendo.cloud/dashboard/<new id>

[verify] running every card through Metabase (this is the acceptance check)

  --- LMS POC — Business Performance (https://bi.onendo.cloud/dashboard/3) ---
   rows  status   card
  ...29 PASS rows...
  -> LMS POC — Business Performance: 29 cards, PASS

  --- LMS POC — Data Quality (https://bi.onendo.cloud/dashboard/<new id>) ---
  ...8 PASS rows...
  -> LMS POC — Data Quality: 8 cards, PASS

[verify] LMS POC — Business Performance: all 29 cards returned real, non-empty data
[verify] LMS POC — Data Quality: all 8 cards returned real, non-empty data
[verify] 2 dashboards, 37 cards total — all non-empty
```

Exit codes: `0` all good · `1` provisioning/SQL error or a board's tile set is wrong ·
`2` a card returned zero rows · `3` dry run.

### Who runs it

The `prism` kanban worker has no shell, no code execution and no HTTP client (see §5),
so a *Prism* card can author and review the pack but cannot POST it. Runs are executed
by the operator profile (`default`) which holds the Metabase admin session and the
shell. Everything the run needs is in this directory — no manual card building.

### Manual fallback (no API access)

Metabase UI: New → Question → Native query → `Lakehouse (Trino)` → paste a card body
from `sql/*.sql` → set Display per the header → Save → add to dashboard
`LMS POC — Business Performance` (01–03) or `LMS POC — Data Quality` (04). The header's
`fmt:` values map to Metabase column formatting (currency/percent). Card names must match
the header exactly, or the next provisioner run creates a second card instead of updating
this one.

## 4. The acceptance check is executable

`provision_metabase.py` runs every card through `POST /api/card/{id}/query` and prints a
row count per card **per dashboard**, flagging `EMPTY` and `ERR`, then asserts each board's
tile set is exactly its pack's card set. "Both dashboards, all cards non-empty" is therefore
a test result, not a claim. Re-run after any `dbt run`:

```bash
python3 provision_metabase.py --base-url https://bi.onendo.cloud \
    --database-name 'Lakehouse (Trino)' && echo "both dashboards still healthy"
```

## 5. Why Prism's worker cannot publish, and what that means for review

The `prism` kanban worker runs with a restricted toolset: file read/write, `web_search`,
kanban tools — **no shell, no code execution, no HTTP client**. Verified again on the
split task (t_ee595fe5, re-checked on t_d2573cb4):

* `execute_code` → `BLOCKED: execute_code runs arbitrary local Python … single-query mode
  runs without a user present to approve it`. So the static check for a change is the
  write-time syntax check (`python` lint, status ok) plus a line-by-line review of the
  parse → group → layout → prune → verify path against the 37 real card headers, and a
  regex check that every card header still matches `HEADER_RE` and that no card body
  contains `GROUP BY currency` / `x: currency` (done on t_d2573cb4: 20 headers in
  01+03, zero currency groups).
* no `terminal` tool in the kanban platform toolset.
* `web_extract` backend is `ddgs` (search-only) → cannot fetch or POST.
* the Metabase admin credential is not in the repo (created in the UI, per `docs/04-metabase.md` §3).

So the split is: **Prism authors + reviews the pack and its numbers; the operator runs
§3 and pastes the verify table back on the card.** A Prism card is only "done" when that
verify output shows both dashboards with every card PASS.

## 6. Known gaps — flagged, not papered over

| Gap | Impact | Owner / status |
|---|---|---|
| ~~**NPL trend over time is not obtainable**~~ | **CLOSED.** `gold.loan_delinquency_snapshot` is append-only over `(as_of_date, delinquency_bucket)`; N7/N8/N9 read it. | Keystone t_51346c5a · **resolved** |
| ~~**No currency dimension in gold**~~ | **CLOSED, then deliberately unused.** `loan_portfolio_summary` grain is `(loan_status, loan_type, currency)` and `loan_event_daily` is `(event_date, currency)` (Keystone t_51346c5a / t_8cbf9a27). Since t_d2573cb4 the POC book is declared single-currency (IDR), so the cards no longer slice by it. | Keystone · resolved (BI side) |
| **Currency revert (t_d2573cb4) — the DATA side is not done.** BI now sums across the book on the single-currency (IDR) assumption, but `gold.*` still exposes `currency` and `src/lms/constants.py` `VALID_CURRENCIES` still lists **USD, EUR, GBP, JPY, CAD, AUD**. The mart therefore still holds six codes until the LMS generator is switched to IDR-only and the marts are rebuilt (`POST /scenarios/loan-book` + `dbt run`). | Until then the aggregated money tiles (P2, P4, P6, P8, P9, Y1–Y3, Y5–Y10) are nominal across those six codes, **not** IDR totals. P10 *"Currency codes in book (must be 1)"* makes that visible on the board instead of hiding it — do not quote a headline money figure while P10 > 1. | Keystone (source constants + rebuild) — flagged, not papered over |
| **NPL snapshot history is short (2 dates: 2026-12-05, 2026-12-06).** | N7 is a 2-point line; it is a real series but not yet a trend you can read a direction from. It grows one date per distinct dataset "now". | Working as designed — no backfill, ever |
| ~~**Payments money is still a nominal multi-currency sum**~~ | **CLOSED, then reverted.** `gold.loan_event_daily` grain is `(event_date, currency)` and `silver.repayment_schedule` carries `currency` (Keystone t_8cbf9a27, materialized by Piston t_b9c989e7). The currency-sliced version was reverted by t_d2573cb4 — payments money tiles are aggregated again. | Keystone · resolved |
| **NPL balances are nominal across currencies** (N3, N5, N8). The snapshot grain has no currency column. | Balances in the NPL pack are labelled nominal and must not be added to a portfolio figure. Rates are unaffected. | Deliberate scope of t_51346c5a · Keystone if a currency-sliced NPL balance is needed |
| **No `charge-off` / write-off concept in the source.** | Buckets stop at `90+`; there is no NPL→loss transition, so no charge-off panel. Adding a bucket before the source emits write-off events would be fabrication. | Keystone (source model) — **out of scope until `src/lms` grows the event** |
| **Orphan cards in the Metabase collection.** After t_d2573cb4 the cards on the dashboard are the aggregated ones; the currency-sliced cards created by t_c825adc3/t_76d6a3f4 are no longer attached to any board: *"Portfolio · Outstanding balance by currency"*, *"Portfolio · Principal originated by currency"*, *"Portfolio · Book by currency"*, *"Payments · Paid vs overdue by currency"*, plus *"NPL · Overdue instalments by due month (proxy trend)"* (superseded by N7 + payments Y6). The three pre-slice cards (*"Portfolio · Outstanding balance"*, *"Portfolio · Principal originated"*, *"Payments · Paid vs overdue by due month"*) were **reused** — the revert updates them in place, so they are no longer orphans. | Cosmetic clutter in the collection only; the provisioner prunes tiles, never cards, so nothing on a dashboard reads them. Archiving/deleting needs Randy's approval (Prism never deletes reports). | Randy — approve archive |
| **`90+` bucket may read 0** on a load where nothing is 90+ DPD. | N1/N2/N3 then read 0 — real, not broken. Populate with `POST /scenarios/loan-book` on the LMS, then `dbt run`. | Randy/Atlas (data injection is their call) |
| **Dashboard split (t_ee595fe5).** Business board renamed in place from `… (Gold)` to `LMS POC — Business Performance` (id **3** kept, URL unchanged); DQ board `LMS POC — Data Quality` created by the first split run. | **Published and verified:** business 29 tiles, DQ 8 tiles, provisioner exit 0 ("2 dashboards, 37 cards total — all non-empty"). | Prism — done |
| **Quarantine panel is empty on a perfectly clean run** by design. | On the DQ board, D5–D8 can return zero rows after a clean load. The provisioner flags it and exits 2, so a clean load blocks the DQ publish — expected behaviour, not a regression. Re-run after a scenario load that trips at least one rule, or accept the flag explicitly with `--allow-empty`. | — (working as intended) |

**Superseded files:** `bi/metabase/delinquency_buckets.sql` and
`bi/metabase/npl_rate_kpi.sql` expected buckets `90-179`/`charge-off` that the mart has
never emitted. They are now deprecation stubs pointing here — see `bi/metabase/README.md`.

## 7. Refresh model

Cards are native queries with caching off (`MB_ENABLE_QUERY_CACHING=false`), so each view
re-queries Trino — the dashboard always reflects the last `dbt run`. No scheduled Metabase
subscription is configured (no SMTP in the stack). "Data as of" (P1) is the freshness
signal, on the dashboard itself; the snapshot cards (N7–N9) additionally show which dates
the pipeline has captured.
