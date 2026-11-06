# Metabase — NPL reporting artifacts (superseded)

**This directory no longer holds hand-built NPL card SQL.** The dashboard is provisioned
by script from a versioned card pack, and the two paste-ready queries that used to live
here are **deprecated**.

| Old file | Status | Replaced by |
|---|---|---|
| `npl_rate_kpi.sql` | **deprecated stub** (no query) | `dashboard/sql/02-npl.sql` → *NPL · NPL rate (90+ / outstanding)* |
| `delinquency_buckets.sql` | **deprecated stub** (no query) | `dashboard/sql/02-npl.sql` → *NPL · Delinquency buckets* |

Why they were retired: both assumed buckets `90-179` and `charge-off`, which
`lakehouse.gold.loan_delinquency` has never emitted (it emits `current` / `30-59` /
`60-89` / `90+`). They also stated NPL rate as a loan-count ratio; the real definition is
**90+ outstanding / total outstanding** (a balance ratio).

## Where to go now

* **Build / refresh both dashboards:** `cd dashboard && python3 provision_metabase.py --database-name 'Lakehouse (Trino)'`
  — see `dashboard/README.md` §3. One run publishes `LMS POC — Business Performance`
  (cards 01–03) and `LMS POC — Data Quality` (card pack 04). The connection display name is
  `Lakehouse (Trino)` (Metabase db id=2; engine `starburst` / `io.trino.jdbc`, host
  `trino:8080`, no password).
* **Definitions:** `dashboard/metric_definitions.md` (one line per tile, plus the
  per-currency money rules).
* **NPL trend:** card *NPL · NPL rate trend (snapshot dates)* over
  `lakehouse.gold.loan_delinquency_snapshot` — real, append-only, one point per date the
  pipeline has run on.
* **Charge-off / NPL→loss:** not buildable. The LMS source has no write-off event; add the
  panel only when `src/lms` grows one. Do not add a `charge-off` bucket speculatively.

Do not add new paste-ready SQL here — extend the card pack in `dashboard/sql/` instead, so
every panel keeps a definition line and a verification run.
