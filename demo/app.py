#!/usr/bin/env python3
"""POC demo control panel — FastAPI harness.

The control panel drives *scenarios* over the single-VM Docker stack:

    PostgreSQL LMS → Debezium CDC → Kafka → Iceberg → dbt (Bronze/Silver/Gold)
                   → Trino → Metabase

The harness reads target URLs from the environment and, where a system is
reachable, talks to it for real; where it is not (or the subsystem is still a
compose TODO), it simulates realistic per-hop behavior — fake latencies, a
data-quality warning, a hard failure, and a failure that opens an incident
ticket in Plane (the ticketing engine).

Endpoints
---------
  GET  /                        → static/index.html (the control panel UI)
  GET  /static/{path}           → static assets
  GET  /health                  → liveness probe
  POST /scenario/{name}[?count=N&mode=clean|dirty|mixed] → run a scenario (JSON)
  POST /scenario/{name}?stream=sse   (or Accept: text/event-stream) → SSE
      · data-injection scenarios (healthy/dirty) call the real LMS /generate API
      · the npl-book scenario calls the real LMS /scenarios/loan-book API

Scenarios: dirty, healthy, failure, incident, npl-book.

Environment (all optional — unreachable/absent → simulated)
-----------------------------------------------------------
  LMS_API_URL        e.g. http://localhost:8000        (source REST API)
  KAFKA_CONNECT_URL  e.g. http://localhost:8083        (Debezium/Kafka Connect)
  TRINO_URL          e.g. http://localhost:8080        (query engine)
  METABASE_URL       e.g. http://localhost:8085        (BI)
  DAGSTER_URL        e.g. http://localhost:3000        (dbt orchestration)
  PLANE_API_URL      e.g. http://localhost:8000/api/v1 (ticketing)
  PLANE_API_KEY      workspace API key (for real tickets)
  PLANE_WORKSPACE    workspace slug
  PLANE_PROJECT_ID   project UUID
  PLANE_UI_URL       UI base for the ticket link
  LATENCY_SCALE      multiplier on simulated latencies (default 1.0; 0.1 = fast)
"""
from __future__ import annotations

import asyncio
import json
import os
import random
import time
import urllib.error
import urllib.request
import uuid
from pathlib import Path

from fastapi import FastAPI, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import FileResponse, JSONResponse, StreamingResponse
from fastapi.staticfiles import StaticFiles

BASE_DIR = Path(__file__).resolve().parent
STATIC_DIR = BASE_DIR / "static"

app = FastAPI(title="POC pipeline control panel", version="0.1.0")
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)

# ─────────────────────────────────────────────────────────────────────────────
# Topology model
# ─────────────────────────────────────────────────────────────────────────────

# Hops are ordered. Each hop lights a *node* and, when it runs, animates the
# *edge* feeding that node (null for the source). Kafka is folded into the
# CDC→Bronze edge (Debezium → Kafka → Iceberg sink).
HOPS = [
    {"id": "lms",    "node": "lms",    "edge": None,          "label": "Source write (Postgres)"},
    {"id": "cdc",    "node": "cdc",    "edge": "lms-cdc",     "label": "Debezium capture"},
    {"id": "kafka",  "node": "bronze", "edge": "cdc-bronze",  "label": "Stream → Iceberg Bronze"},
    {"id": "silver", "node": "silver", "edge": "bronze-silver", "label": "dbt Silver transform"},
    {"id": "gold",   "node": "gold",   "edge": "silver-gold", "label": "dbt Gold aggregate + DQ"},
    {"id": "bi",     "node": "bi",     "edge": "gold-bi",     "label": "Trino query → Metabase"},
]

SCENARIOS = {
    "healthy": {
        "title": "Healthy end-to-end",
        "status": "success",
        "hops": {
            "lms":    {"latency": 45,    "status": "success", "metric": "1,284 rows",
                       "message": "Loan write committed to lms-postgres (wal_level=logical)"},
            "cdc":    {"latency": 320,   "status": "success", "metric": "1,284 changes",
                       "message": "Debezium lms-connector: snapshot + streaming, lag 0 ms"},
            "kafka":  {"latency": 210,   "status": "success", "metric": "1,284 msgs",
                       "message": "Kafka → Iceberg sink wrote Bronze table (no retries)"},
            "silver": {"latency": 2600,  "status": "success", "metric": "1,284 rows",
                       "message": "dbt Silver: dedupe + type coercion, 0 schema drift"},
            "gold":   {"latency": 1900,  "status": "success", "metric": "0 failed",
                       "message": "dbt Gold: loan_portfolio aggregate, all DQ checks pass"},
            "bi":     {"latency": 160,   "status": "success", "metric": "41 ms",
                       "message": "Trino query 41 ms → Metabase dashboard refreshed"},
        },
    },
    "dirty": {
        "title": "Dirty data → DQ warning",
        "status": "warning",
        "hops": {
            "lms":    {"latency": 45,    "status": "success", "metric": "1,284 rows",
                       "message": "Loan write committed (14 rows with NULL days_past_due)"},
            "cdc":    {"latency": 320,   "status": "success", "metric": "1,284 changes",
                       "message": "Debezium captured all changes, incl. NULL dpd rows"},
            "kafka":  {"latency": 210,   "status": "success", "metric": "1,284 msgs",
                       "message": "Iceberg Bronze ingest OK — schema drift tolerated"},
            "silver": {"latency": 2600,  "status": "success", "metric": "1,284 rows",
                       "message": "dbt Silver: 14 rows flagged missing days_past_due"},
            "gold":   {"latency": 1900,  "status": "warning", "metric": "14 / 1,284 null",
                       "message": "DQ check FAILED: days_past_due null rate 1.1% > 0.5% threshold"},
            "bi":     {"latency": 160,   "status": "success", "metric": "1,284 loans",
                       "message": "Trino → Metabase dashboard shows a DQ banner"},
        },
    },
    "failure": {
        "title": "Pipeline failure (Iceberg sink)",
        "status": "failed",
        "hops": {
            "lms":    {"latency": 45,    "status": "success", "metric": "1,284 rows",
                       "message": "Loan write committed to lms-postgres"},
            "cdc":    {"latency": 320,   "status": "success", "metric": "1,284 changes",
                       "message": "Debezium captured changes, published to Kafka"},
            "kafka":  {"latency": 900,   "status": "failure", "metric": "commit failed",
                       "message": "Iceberg sink commit FAILED: MinIO 403 (bad S3 creds) — retries exhausted"},
            "silver": {"status": "skipped"},
            "gold":   {"status": "skipped"},
            "bi":     {"status": "skipped"},
        },
    },
    "incident": {
        "title": "DQ SLO breach → incident ticket",
        "status": "incident",
        "hops": {
            "lms":    {"latency": 45,    "status": "success", "metric": "9,412 rows",
                       "message": "Bulk loan import committed (nightly batch)"},
            "cdc":    {"latency": 340,   "status": "success", "metric": "9,412 changes",
                       "message": "Debezium captured batch, lag 0 ms"},
            "kafka":  {"latency": 230,   "status": "success", "metric": "9,412 msgs",
                       "message": "Iceberg Bronze ingest OK"},
            "silver": {"latency": 2800,  "status": "success", "metric": "9,412 rows",
                       "message": "dbt Silver transform OK"},
            "gold":   {"latency": 2200,  "status": "failure", "metric": "SLO breach",
                       "message": "DQ SLO BREACH: days_past_due null rate 6.8% > 2% pager threshold"},
            "bi":     {"status": "skipped"},
        },
    },
    "npl-book": {
        "title": "NPL loan book (all delinquency buckets)",
        "status": "success",
        "hops": {
            "lms":    {"latency": 60,    "status": "success", "metric": None,
                       "message": "Loan book written across 5 delinquency buckets"},
            "cdc":    {"latency": 320,   "status": "success", "metric": "5 buckets",
                       "message": "Debezium captured disbursement + payment events for every bucket"},
            "kafka":  {"latency": 210,   "status": "success", "metric": "5 buckets",
                       "message": "Iceberg Bronze ingest OK"},
            "silver": {"latency": 2600,  "status": "success", "metric": "0 failed",
                       "message": "dbt Silver: clean rows, 0 DQ failures"},
            "gold":   {"latency": 1900,  "status": "success", "metric": "5 buckets",
                       "message": "dbt Gold loan_delinquency populated: current/30-59/60-89/90-179/charge-off"},
            "bi":     {"latency": 160,   "status": "success", "metric": "5 buckets",
                       "message": "Trino → Metabase NPL dashboard refreshed"},
        },
    },
}

# External systems the harness may reach (target URLs from env).
SYSTEMS = [
    ("lms_api",       "LMS API",       "LMS_API_URL"),
    ("kafka_connect", "Kafka Connect", "KAFKA_CONNECT_URL"),
    ("trino",         "Trino",         "TRINO_URL"),
    ("metabase",      "Metabase",      "METABASE_URL"),
    ("dagster",       "Dagster",       "DAGSTER_URL"),
    ("plane",         "Plane",         "PLANE_API_URL"),
]

_DEFAULT_URLS = {
    "LMS_API_URL": "http://localhost:8000",
    "KAFKA_CONNECT_URL": "http://localhost:8083",
    "TRINO_URL": "http://localhost:8080",
    "METABASE_URL": "http://localhost:8085",
    "DAGSTER_URL": "http://localhost:3000",
    "PLANE_API_URL": "http://localhost:8000/api/v1",
}


def _latency_ms(ms: int) -> float:
    scale = float(os.environ.get("LATENCY_SCALE", "1.0"))
    jitter = random.uniform(0.9, 1.1)
    return max(1.0, ms * scale * jitter)


def _url(env_key: str) -> str:
    return os.environ.get(env_key, _DEFAULT_URLS.get(env_key, "")).rstrip("/")


def _reachable(url: str, timeout: float = 1.5) -> bool:
    if not url:
        return False
    try:
        req = urllib.request.Request(url, method="GET")
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return 200 <= r.status < 500
    except Exception:
        return False


async def _probe_systems() -> dict:
    """Snapshot which target systems are reachable (real) vs simulated."""

    async def one(sid, label, env_key):
        url = _url(env_key)
        ok = await asyncio.to_thread(_reachable, url)
        return {"id": sid, "label": label, "url": url, "reachable": bool(ok)}

    results = await asyncio.gather(*(one(*s) for s in SYSTEMS))
    return {r["id"]: r for r in results}


# Data-injection scenarios (healthy/dirty) drive the real LMS /generate endpoint.
# Default mode per scenario when the caller doesn't pass an explicit mode; the
# frontend inject control passes an explicit mode (clean|dirty|mixed) instead.
DATA_MODES = {"healthy": "clean", "dirty": "dirty"}
DEFAULT_INJECT_COUNT = 10000

# The npl-book scenario drives the real LMS /scenarios/loan-book endpoint (a
# deterministic loan book that populates every dbt Gold delinquency bucket).
NPL_BOOK_SCENARIO = "npl-book"
NPL_DEFAULT_PER_BUCKET = 5


def _parse_int(value) -> int | None:
    if value is None or value == "":
        return None
    try:
        return int(value)
    except (TypeError, ValueError):
        return None


def _lms_generate(count: int, mode: str) -> dict:
    """POST {LMS_API_URL}/generate?count=N&mode=MODE → parsed JSON body."""
    base = _url("LMS_API_URL")
    url = f"{base}/generate?count={count}&mode={mode}"
    req = urllib.request.Request(url, method="POST")
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.load(r)


async def _inject_lms(count: int, mode: str) -> dict:
    """Call the real LMS /generate endpoint; return {ok, count, error}."""
    try:
        resp = await asyncio.to_thread(_lms_generate, count, mode)
    except Exception as exc:  # noqa: BLE001
        return {"ok": False, "count": count, "error": str(exc)}

    # LMS API response shape is still being finalized — extract the injected
    # count defensively from whichever common field carries it.
    injected = None
    if isinstance(resp, dict):
        for key in ("count", "injected", "rows", "total", "generated"):
            if isinstance(resp.get(key), int):
                injected = resp[key]
                break
    return {
        "ok": True,
        "count": injected if injected is not None else count,
        "error": None,
    }


def _lms_loan_book(n_per_bucket: int) -> dict:
    """POST {LMS_API_URL}/scenarios/loan-book → parsed JSON body."""
    base = _url("LMS_API_URL")
    url = f"{base}/scenarios/loan-book"
    req = urllib.request.Request(
        url,
        data=json.dumps({"n_per_bucket": n_per_bucket}).encode(),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.load(r)


async def _inject_loan_book(n_per_bucket: int) -> dict:
    """Call the real LMS /scenarios/loan-book endpoint; return {ok, ...}."""
    try:
        resp = await asyncio.to_thread(_lms_loan_book, n_per_bucket)
    except Exception as exc:  # noqa: BLE001
        return {"ok": False, "n_per_bucket": n_per_bucket, "error": str(exc)}

    created = resp.get("created_loans") if isinstance(resp, dict) else None
    payments = resp.get("payments") if isinstance(resp, dict) else None
    per_bucket = resp.get("per_bucket") if isinstance(resp, dict) else None
    return {
        "ok": True,
        "n_per_bucket": n_per_bucket,
        "created_loans": created,
        "payments": payments,
        "per_bucket": per_bucket,
        "error": None,
    }


def _simulated_ticket(run_id: str, title: str, note: str) -> dict:
    return {
        "id": f"sim-{uuid.uuid4().hex[:8]}",
        "title": title,
        "url": None,
        "priority": "urgent",
        "simulated": True,
        "note": note,
    }


async def _create_plane_ticket(run_id: str, breach_msg: str) -> dict:
    """Open a real ticket in Plane when configured; otherwise simulate one."""
    base = _url("PLANE_API_URL")
    key = os.environ.get("PLANE_API_KEY", "")
    ws = os.environ.get("PLANE_WORKSPACE", "")
    proj = os.environ.get("PLANE_PROJECT_ID", "")
    title = f"[INCIDENT] gold DQ SLO breach (run {run_id[:8]})"

    if not (key and ws and proj):
        return _simulated_ticket(
            run_id, title, note="PLANE_API_KEY / PLANE_WORKSPACE / PLANE_PROJECT_ID not set"
        )

    payload = {
        "name": title,
        "description_html": f"<p>{breach_msg}</p><p>Auto-opened by the POC control panel.</p>",
        "priority": "urgent",
    }
    url = f"{base}/workspaces/{ws}/projects/{proj}/issues/"

    def _post() -> dict:
        req = urllib.request.Request(
            url,
            data=json.dumps(payload).encode(),
            headers={"Content-Type": "application/json", "X-API-Key": key},
            method="POST",
        )
        with urllib.request.urlopen(req, timeout=8) as r:
            return json.load(r)

    try:
        resp = await asyncio.to_thread(_post)
    except Exception as exc:  # noqa: BLE001
        return _simulated_ticket(run_id, title, note=f"Plane unreachable: {exc}")

    ui = os.environ.get("PLANE_UI_URL", "http://localhost:3000")
    return {
        "id": resp.get("id"),
        "title": title,
        "url": f"{ui}/{ws}/projects/{proj}/issues/{resp.get('id')}",
        "priority": "urgent",
        "simulated": False,
        "note": "Created via Plane REST API",
    }


# Scenario → the pipeline stage the Grafana topology should mark failed when the
# simulated failure/incident runs. The demo pushes a `demo_failure{stage=...}`
# gauge (1 = failed) to the pushgateway; the topology query multiplies
# pipeline_stage_health by (1 - demo_failure) to override that stage to 0/red.
SCENARIO_FAILED_STAGE = {
    "failure": "Iceberg",  # "Pipeline failure (Iceberg sink)"
    "incident": "Gold",    # "DQ SLO breach → incident ticket"
}


def _push_demo_failure(stage: str | None) -> None:
    """Push (or clear) demo_failure{stage=...} to the pushgateway (best-effort).

    A non-None stage marks that stage failed in the Grafana topology; None
    clears the failure (PUT an empty group so every stage reads healthy).
    """
    pg_url = os.environ.get("PUSHGATEWAY_URL", "http://pushgateway:9091")
    body = "" if stage is None else f'demo_failure{{stage="{stage}"}} 1\n'

    def _put() -> None:
        req = urllib.request.Request(
            f"{pg_url}/metrics/job/demo-scenario",
            data=body.encode(),
            headers={"Content-Type": "text/plain; version=0.0.4"},
            method="PUT",
        )
        with urllib.request.urlopen(req, timeout=5):
            pass

    try:
        _put()
    except Exception:  # noqa: BLE001 — monitoring is best-effort
        pass


async def generate(name: str, count: int | None = None, mode: str | None = None):
    """Async generator yielding (event, payload) tuples for a scenario run.

    Data-injection scenarios (healthy/dirty) replace the simulated source write
    with a real call to the LMS ``/generate`` endpoint (POST, ``count`` + ``mode``
    params). The ``npl-book`` scenario calls the real LMS ``/scenarios/loan-book``
    endpoint (POST, ``count`` = loans per delinquency bucket). Every other hop —
    and the failure/incident scenarios — are unchanged.
    """
    scenario = SCENARIOS[name]
    run_id = str(uuid.uuid4())
    started = time.time()

    inject_mode = mode or DATA_MODES.get(name)
    inject_count = max(0, count) if count is not None else DEFAULT_INJECT_COUNT

    systems = await _probe_systems()
    yield "start", {
        "scenario": name,
        "id": run_id,
        "title": scenario["title"],
        "systems": systems,
    }

    # Reflect a simulated failure/incident in Grafana by pushing demo_failure.
    await asyncio.to_thread(_push_demo_failure, SCENARIO_FAILED_STAGE.get(name))

    hop_results: list[dict] = []
    failed = False
    injected = None

    for hop in HOPS:
        cfg = scenario["hops"].get(hop["id"], {"status": "skipped"})
        final_status = cfg.get("status", "success")

        # Anything after a failure is skipped, not run.
        if failed or final_status == "skipped":
            payload = {
                "id": hop["id"], "node": hop["node"], "edge": hop["edge"],
                "label": hop["label"], "status": "skipped",
                "latency_ms": 0, "message": "skipped (upstream failed)",
                "metric": None, "simulated": True,
            }
            hop_results.append(payload)
            yield "hop_done", payload
            continue

        yield "hop_running", {
            "id": hop["id"], "node": hop["node"], "edge": hop["edge"],
            "label": hop["label"],
        }

        latency = cfg.get("latency", 100)
        simulated = True
        message = cfg.get("message", "")
        metric = cfg.get("metric")

        # Source hop of a data-injection scenario → real LMS /generate.
        if hop["id"] == "lms" and name == NPL_BOOK_SCENARIO:
            n_per_bucket = max(1, count) if count is not None else NPL_DEFAULT_PER_BUCKET
            result = await _inject_loan_book(n_per_bucket)
            if result["ok"] and result["created_loans"] is not None:
                simulated = False
                buckets = result["per_bucket"] or {}
                injected = {
                    "count": result["created_loans"],
                    "mode": "loan-book",
                    "real": True,
                    "payments": result["payments"],
                    "per_bucket": buckets,
                }
                metric = f"{result['created_loans']:,} loans"
                message = (
                    f"LMS /scenarios/loan-book: {result['created_loans']} loans, "
                    f"{result['payments']} payments across {len(buckets)} buckets"
                )
            else:
                # Surface the real error: no fabricated metrics, hop shows warning.
                final_status = "warning"
                metric = None
                message = (
                    f"LMS /scenarios/loan-book unreachable "
                    f"({result.get('error')}) — nothing injected"
                )
        elif hop["id"] == "lms" and inject_mode is not None:
            if inject_count > 0:
                result = await _inject_lms(inject_count, inject_mode)
                if result["ok"]:
                    simulated = False
                    injected = {"count": result["count"], "mode": inject_mode, "real": True}
                    metric = f"{result['count']:,} rows"
                    message = (
                        f"LMS /generate: {result['count']:,} rows injected "
                        f"(mode={inject_mode})"
                    )
                else:
                    injected = {"count": inject_count, "mode": inject_mode, "real": False}
                    message = (
                        f"LMS /generate unreachable ({result['error']}) — "
                        f"simulated source write"
                    )
            else:
                injected = {"count": 0, "mode": inject_mode, "real": False}
                metric = "0 rows"
                message = "LMS /generate skipped (count=0)"

        await asyncio.sleep(_latency_ms(latency) / 1000.0)

        payload = {
            "id": hop["id"], "node": hop["node"], "edge": hop["edge"],
            "label": hop["label"], "status": final_status,
            "latency_ms": round(_latency_ms(latency)),
            "message": message,
            "metric": metric,
            "simulated": simulated,
        }
        hop_results.append(payload)
        yield "hop_done", payload

        if final_status == "failure":
            failed = True

    ticket = None
    if scenario["status"] == "incident":
        breach = scenario["hops"]["gold"]["message"]
        ticket = await _create_plane_ticket(run_id, breach)
        yield "ticket", ticket

    duration_ms = int((time.time() - started) * 1000)
    yield "done", {
        "scenario": name,
        "title": scenario["title"],
        "status": scenario["status"],
        "duration_ms": duration_ms,
        "hops": hop_results,
        "ticket": ticket,
        "systems": systems,
        "injected": injected,
    }


def _sse(event: str, data: dict) -> str:
    return f"event: {event}\ndata: {json.dumps(data)}\n\n"


# ─────────────────────────────────────────────────────────────────────────────
# Routes
# ─────────────────────────────────────────────────────────────────────────────

@app.get("/health")
async def health():
    return {"status": "ok"}


@app.get("/", include_in_schema=False)
async def index():
    return FileResponse(STATIC_DIR / "index.html")


def _wants_sse(request: Request) -> bool:
    accept = request.headers.get("accept", "")
    return request.query_params.get("stream") == "sse" or "text/event-stream" in accept


@app.post("/scenario/{name}")
async def run_scenario(name: str, request: Request):
    if name not in SCENARIOS:
        return JSONResponse(
            {"error": f"unknown scenario '{name}'", "scenarios": sorted(SCENARIOS)},
            status_code=404,
        )

    params = request.query_params
    count = _parse_int(params.get("count"))
    mode = params.get("mode")
    if mode and mode not in ("clean", "dirty", "mixed"):
        mode = None

    if _wants_sse(request):
        async def stream():
            async for event, payload in generate(name, count=count, mode=mode):
                yield _sse(event, payload)

        return StreamingResponse(
            stream(),
            media_type="text/event-stream",
            headers={
                "Cache-Control": "no-cache",
                "X-Accel-Buffering": "no",
                "Connection": "keep-alive",
            },
        )

    # JSON: collect final per-hop results + summary.
    result = {
        "scenario": name, "id": None, "status": None, "hops": [],
        "ticket": None, "systems": {}, "injected": None,
    }
    async for event, payload in generate(name, count=count, mode=mode):
        if event == "start":
            result["id"] = payload["id"]
            result["title"] = payload["title"]
            result["systems"] = payload["systems"]
        elif event == "hop_done":
            result["hops"].append(payload)
        elif event == "ticket":
            result["ticket"] = payload
        elif event == "done":
            result["status"] = payload["status"]
            result["duration_ms"] = payload["duration_ms"]
            result["injected"] = payload.get("injected")
    return result


app.mount("/static", StaticFiles(directory=STATIC_DIR), name="static")


if __name__ == "__main__":
    import uvicorn

    uvicorn.run("app:app", host="0.0.0.0", port=int(os.environ.get("PORT", "8000")), reload=False)
