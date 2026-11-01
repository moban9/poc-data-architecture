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
  POST /scenario/{name}         → run a scenario, return per-hop results (JSON)
  POST /scenario/{name}?stream=sse   (or Accept: text/event-stream) → SSE

Scenarios: dirty, healthy, failure, incident.

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


async def generate(name: str):
    """Async generator yielding (event, payload) tuples for a scenario run."""
    scenario = SCENARIOS[name]
    run_id = str(uuid.uuid4())
    started = time.time()

    systems = await _probe_systems()
    yield "start", {
        "scenario": name,
        "id": run_id,
        "title": scenario["title"],
        "systems": systems,
    }

    hop_results: list[dict] = []
    failed = False

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
        await asyncio.sleep(_latency_ms(latency) / 1000.0)

        payload = {
            "id": hop["id"], "node": hop["node"], "edge": hop["edge"],
            "label": hop["label"], "status": final_status,
            "latency_ms": round(_latency_ms(latency)),
            "message": cfg.get("message", ""),
            "metric": cfg.get("metric"),
            "simulated": True,
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

    if _wants_sse(request):
        async def stream():
            async for event, payload in generate(name):
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
    result = {"scenario": name, "id": None, "status": None, "hops": [], "ticket": None, "systems": {}}
    async for event, payload in generate(name):
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
    return result


app.mount("/static", StaticFiles(directory=STATIC_DIR), name="static")


if __name__ == "__main__":
    import uvicorn

    uvicorn.run("app:app", host="0.0.0.0", port=int(os.environ.get("PORT", "8000")), reload=False)
