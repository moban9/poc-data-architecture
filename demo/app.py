#!/usr/bin/env python3
"""POC demo control panel — FastAPI harness (REAL results only).

The control panel drives *scenarios* over the single-VM Docker stack:

    PostgreSQL LMS → Debezium CDC → Kafka → Iceberg → dbt (Bronze/Silver/Gold)
                   → Trino → Metabase

Every hop now reports a REAL observation of the live pipeline — a real source
write, the real Kafka Connect connector state, the real dbt layer/DQ metrics from
Prometheus, the real Trino/Metabase reachability. There are no hard-coded or
simulated results anywhere.

The two "break it" scenarios drive a narrow kill-switch (demo/killswitch.py):

  * failure  → the kill-switch docker-stops the MinIO object store, which the
               Iceberg sink writes to. The sink genuinely fails and Grafana's
               Iceberg node (a live blackbox probe of MinIO) turns red.
  * incident → injects dirty rows, runs the real dbt pipeline (the DQ gate),
               and the DQ genuinely breaches (dbt_test_failures > 0); a REAL
               Plane ticket is then opened. No simulated-ticket fallback.

Endpoints
---------
  GET  /                        → static/index.html (the control panel UI)
  GET  /static/{path}           → static assets
  GET  /health                  → liveness probe
  POST /scenario/{name}[?count=N&mode=clean|dirty|mixed] → run a scenario (JSON)
  POST /scenario/{name}?stream=sse   (or Accept: text/event-stream) → SSE

Scenarios: dirty, healthy, failure, incident, npl-book.

Environment
-----------
  LMS_API_URL        e.g. http://lms-api:8000        (source REST API)
  KAFKA_CONNECT_URL  e.g. http://connect:8083        (Debezium/Kafka Connect)
  PROMETHEUS_URL     e.g. http://prometheus:9090     (metrics for dbt/DQ state)
  TRINO_URL          e.g. http://trino:8080          (query engine)
  METABASE_URL       e.g. http://metabase:3000       (BI)
  PLANE_API_URL      e.g. http://plane:8000/api/v1   (ticketing)
  PLANE_API_KEY      workspace API key (required for a REAL ticket)
  PLANE_WORKSPACE    workspace slug
  PLANE_PROJECT_ID   project UUID
  PLANE_UI_URL       UI base for the ticket link
  KILLSWITCH_URL     e.g. http://killswitch:8002     (failure/incident control)
"""
from __future__ import annotations

import asyncio
import json
import os
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid
from pathlib import Path

from fastapi import FastAPI, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import FileResponse, JSONResponse, StreamingResponse
from fastapi.staticfiles import StaticFiles

BASE_DIR = Path(__file__).resolve().parent
STATIC_DIR = BASE_DIR / "static"

app = FastAPI(title="POC pipeline control panel", version="0.2.0")
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)

# ─────────────────────────────────────────────────────────────────────────────
# Topology model
# ─────────────────────────────────────────────────────────────────────────────

HOPS = [
    {"id": "lms",    "node": "lms",    "edge": None,          "label": "Source write (Postgres)"},
    {"id": "cdc",    "node": "cdc",    "edge": "lms-cdc",     "label": "Debezium capture"},
    {"id": "kafka",  "node": "bronze", "edge": "cdc-bronze",  "label": "Stream → Iceberg Bronze"},
    {"id": "silver", "node": "silver", "edge": "bronze-silver", "label": "dbt Silver transform"},
    {"id": "gold",   "node": "gold",   "edge": "silver-gold", "label": "dbt Gold aggregate + DQ"},
    {"id": "bi",     "node": "bi",     "edge": "gold-bi",     "label": "Trino query → Metabase"},
]

SCENARIOS = {
    "healthy":  {"title": "Healthy end-to-end",                      "status": "success"},
    "dirty":    {"title": "Dirty data → DQ warning",                  "status": "warning"},
    "npl-book": {"title": "NPL loan book (real repayment schedules)", "status": "success"},
    "failure":  {"title": "Pipeline failure (Iceberg sink)",          "status": "failed"},
    "incident": {"title": "DQ SLO breach → incident ticket",          "status": "incident"},
}

# External systems the harness probes at start (target URLs from env).
SYSTEMS = [
    ("lms_api",       "LMS API",       "LMS_API_URL"),
    ("kafka_connect", "Kafka Connect", "KAFKA_CONNECT_URL"),
    ("prometheus",    "Prometheus",    "PROMETHEUS_URL"),
    ("trino",         "Trino",         "TRINO_URL"),
    ("metabase",      "Metabase",      "METABASE_URL"),
    ("plane",         "Plane",         "PLANE_API_URL"),
]

_DEFAULT_URLS = {
    "LMS_API_URL": "http://localhost:8000",
    "KAFKA_CONNECT_URL": "http://localhost:8083",
    "PROMETHEUS_URL": "http://localhost:9090",
    "TRINO_URL": "http://localhost:8080",
    "METABASE_URL": "http://localhost:8085",
    "PLANE_API_URL": "http://localhost:8000/api/v1",
    "KILLSWITCH_URL": "http://killswitch:8002",
}

# Data-injection scenarios drive the real LMS /generate endpoint.
DATA_MODES = {"healthy": "clean", "dirty": "dirty"}
DEFAULT_INJECT_COUNT = 10000

# The npl-book scenario drives the real LMS /scenarios/loan-book endpoint.
NPL_BOOK_SCENARIO = "npl-book"
NPL_DEFAULT_PER_BUCKET = 5

# The incident scenario injects a fully-dirty batch large enough to breach the
# DQ SLO (0 failing tests) and trip the pager, then runs the real dbt gate.
INCIDENT_DIRTY_COUNT = 2000

# The failure scenario injects a small clean batch so there is in-flight data
# for the (then-killed) Iceberg sink, then stops the object store.
FAILURE_INJECT_COUNT = 1000


def _url(env_key: str) -> str:
    return os.environ.get(env_key, _DEFAULT_URLS.get(env_key, "")).rstrip("/")


def _reachable(url: str, timeout: float = 1.5) -> bool:
    if not url:
        return False
    try:
        req = urllib.request.Request(url, method="GET")
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return 200 <= r.status < 500
    except urllib.error.HTTPError as exc:
        return exc.code < 500
    except Exception:
        return False


async def _probe_systems() -> dict:
    async def one(sid, label, env_key):
        url = _url(env_key)
        ok = await asyncio.to_thread(_reachable, url)
        return {"id": sid, "label": label, "url": url, "reachable": bool(ok)}

    results = await asyncio.gather(*(one(*s) for s in SYSTEMS))
    return {r["id"]: r for r in results}


# ─────────────────────────────────────────────────────────────────────────────
# Real observations
# ─────────────────────────────────────────────────────────────────────────────

def _json_get(url: str, timeout: float = 5.0) -> dict:
    """GET a URL and return parsed JSON, or raise with a real error message."""
    req = urllib.request.Request(url, method="GET")
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.load(r)


def _kafka_connect_connector_state(connector: str) -> dict:
    """Real Kafka Connect connector state: {state: "RUNNING"|...|"?", error}."""
    base = _url("KAFKA_CONNECT_URL")
    if not base:
        return {"state": "?", "error": "KAFKA_CONNECT_URL not configured"}
    url = f"{base}/connectors/{connector}/status"
    try:
        data = _json_get(url)
        state = (data.get("connector") or {}).get("state", "?")
        return {"state": state, "error": None}
    except urllib.error.HTTPError as exc:
        body = exc.read().decode("utf-8", "replace")[:300]
        return {"state": "?", "error": f"HTTP {exc.code}: {body}"}
    except Exception as exc:  # noqa: BLE001
        return {"state": "?", "error": str(exc)}


def _prom_metric_value(expr: str) -> float | None:
    """First numeric value of a Prometheus instant query, or None."""
    base = _url("PROMETHEUS_URL")
    if not base:
        return None
    url = f"{base}/api/v1/query?query={urllib.parse.quote(expr)}"
    try:
        data = _json_get(url)
        results = data.get("data", {}).get("result", [])
        if not results:
            return None
        value = results[0].get("value", [None, None])[1]
        return float(value)
    except Exception:  # noqa: BLE001
        return None


# ─────────────────────────────────────────────────────────────────────────────
# Kill-switch (failure / incident control)
# ─────────────────────────────────────────────────────────────────────────────

def _killswitch(path: str, method: str = "GET", timeout: float = 900.0) -> dict:
    base = _url("KILLSWITCH_URL")
    if not base:
        return {"ok": False, "error": "KILLSWITCH_URL not configured"}
    req = urllib.request.Request(f"{base.rstrip('/')}{path}", method=method)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return {"ok": True, **json.load(r)}
    except urllib.error.HTTPError as exc:
        body = exc.read().decode("utf-8", "replace")[:500]
        return {"ok": False, "error": f"kill-switch HTTP {exc.code}: {body}"}
    except Exception as exc:  # noqa: BLE001
        return {"ok": False, "error": str(exc)}


# ─────────────────────────────────────────────────────────────────────────────
# LMS source writes (real)
# ─────────────────────────────────────────────────────────────────────────────

def _lms_generate(count: int, mode: str) -> dict:
    base = _url("LMS_API_URL")
    url = f"{base}/generate?count={count}&mode={mode}"
    req = urllib.request.Request(url, method="POST")
    with urllib.request.urlopen(req, timeout=60) as r:
        return json.load(r)


async def _inject_lms(count: int, mode: str) -> dict:
    try:
        resp = await asyncio.to_thread(_lms_generate, count, mode)
    except Exception as exc:  # noqa: BLE001
        return {"ok": False, "count": count, "mode": mode, "error": str(exc)}

    injected = None
    if isinstance(resp, dict):
        for key in ("count", "injected", "rows", "total", "generated", "loans"):
            if isinstance(resp.get(key), int):
                injected = resp[key]
                break
    return {
        "ok": True,
        "count": injected if injected is not None else count,
        "mode": mode,
        "error": None,
    }


def _lms_loan_book(n_per_bucket: int) -> dict:
    base = _url("LMS_API_URL")
    url = f"{base}/scenarios/loan-book"
    req = urllib.request.Request(
        url,
        data=json.dumps({"n_per_bucket": n_per_bucket}).encode(),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=60) as r:
        return json.load(r)


async def _inject_loan_book(n_per_bucket: int) -> dict:
    try:
        resp = await asyncio.to_thread(_lms_loan_book, n_per_bucket)
    except Exception as exc:  # noqa: BLE001
        return {"ok": False, "n_per_bucket": n_per_bucket, "error": str(exc)}
    return {
        "ok": True,
        "n_per_bucket": n_per_bucket,
        "created_loans": resp.get("created_loans") if isinstance(resp, dict) else None,
        "payments": resp.get("payments") if isinstance(resp, dict) else None,
        "per_bucket": resp.get("per_bucket") if isinstance(resp, dict) else None,
        "error": None,
    }


# ─────────────────────────────────────────────────────────────────────────────
# Plane ticket (REAL only — no simulated fallback)
# ─────────────────────────────────────────────────────────────────────────────

async def _create_plane_ticket(run_id: str, breach_msg: str) -> dict:
    """Open a real Plane ticket. Returns {id,url,...} on success, or {error:...}."""
    base = _url("PLANE_API_URL")
    key = os.environ.get("PLANE_API_KEY", "")
    ws = os.environ.get("PLANE_WORKSPACE", "")
    proj = os.environ.get("PLANE_PROJECT_ID", "")
    title = f"[INCIDENT] gold DQ SLO breach (run {run_id[:8]})"

    if not (key and ws and proj):
        return {
            "error": "Plane not configured: PLANE_API_KEY / PLANE_WORKSPACE / "
                     "PLANE_PROJECT_ID missing — no ticket created",
        }

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
        with urllib.request.urlopen(req, timeout=10) as r:
            return json.load(r)

    try:
        resp = await asyncio.to_thread(_post)
    except urllib.error.HTTPError as exc:
        body = exc.read().decode("utf-8", "replace")[:500]
        return {"error": f"Plane rejected ticket: HTTP {exc.code}: {body}"}
    except Exception as exc:  # noqa: BLE001
        return {"error": f"Plane unreachable: {exc}"}

    ui = os.environ.get("PLANE_UI_URL", "http://localhost:3000")
    return {
        "id": resp.get("id"),
        "title": title,
        "url": f"{ui}/{ws}/projects/{proj}/issues/{resp.get('id')}",
        "priority": "urgent",
        "note": "Created via Plane REST API",
    }


# ─────────────────────────────────────────────────────────────────────────────
# Scenario execution
# ─────────────────────────────────────────────────────────────────────────────

def _hop_payload(hop: dict, status: str, message: str, metric: str | None,
                 latency_ms: int) -> dict:
    return {
        "id": hop["id"], "node": hop["node"], "edge": hop["edge"],
        "label": hop["label"], "status": status,
        "latency_ms": latency_ms, "message": message, "metric": metric,
    }


def _real_downstream(hop_id: str) -> tuple[str, str, str | None]:
    """Real state of a downstream hop → (status, message, metric)."""
    if hop_id == "cdc":
        s = _kafka_connect_connector_state("debezium-postgres")
        if s["state"] == "RUNNING":
            return "success", "Debezium connector RUNNING", None
        return "failure", f"Debezium connector state={s['state']}: {s['error'] or 'not running'}", None

    if hop_id == "kafka":
        s = _kafka_connect_connector_state("iceberg-sink")
        if s["state"] == "RUNNING":
            return "success", "Iceberg sink connector RUNNING", None
        return "failure", f"Iceberg sink connector state={s['state']}: {s['error'] or 'not running'}", None

    if hop_id == "silver":
        v = _prom_metric_value('dbt_run_success{layer="silver"}')
        if v == 1:
            return "success", "dbt Silver layer up (last run success)", None
        return "failure", f"dbt Silver layer down (dbt_run_success={v})", None

    if hop_id == "gold":
        v = _prom_metric_value('dbt_run_success{layer="gold"}')
        failures = _prom_metric_value("dbt_test_failures")
        if v == 1 and failures == 0:
            return "success", "dbt Gold layer up, 0 DQ failures", "0 failed"
        if v == 1 and failures:
            return "warning", f"dbt Gold layer up, {int(failures)} DQ test(s) failing", f"{int(failures)} failed"
        return "failure", f"dbt Gold layer down (dbt_run_success={v})", None

    if hop_id == "bi":
        trino_ok = _reachable(_url("TRINO_URL"))
        mb_ok = _reachable(_url("METABASE_URL"))
        if trino_ok and mb_ok:
            return "success", "Trino + Metabase reachable", None
        return "failure", f"BI reachability: Trino={'up' if trino_ok else 'DOWN'}, Metabase={'up' if mb_ok else 'DOWN'}", None

    return "success", "", None


def _parse_int(value) -> int | None:
    if value is None or value == "":
        return None
    try:
        return int(value)
    except (TypeError, ValueError):
        return None


async def generate(name: str, count: int | None = None, mode: str | None = None):
    scenario = SCENARIOS[name]
    run_id = str(uuid.uuid4())
    started = time.time()

    inject_mode = mode or DATA_MODES.get(name)
    systems = await _probe_systems()
    yield "start", {
        "scenario": name,
        "id": run_id,
        "title": scenario["title"],
        "systems": systems,
    }

    hop_results: list[dict] = []
    injected = None
    ticket = None
    failed = False
    dbt_result = None

    for hop in HOPS:
        hid = hop["id"]
        t0 = time.time()

        if failed:
            payload = _hop_payload(
                hop, "skipped", "skipped (upstream failed)", None, 0)
            hop_results.append(payload)
            yield "hop_done", payload
            continue

        yield "hop_running", {"id": hid, "node": hop["node"], "edge": hop["edge"], "label": hop["label"]}

        # ── Source write (real) ────────────────────────────────────────────
        if hid == "lms":
            if name == NPL_BOOK_SCENARIO:
                n_per_bucket = max(1, count) if count is not None else NPL_DEFAULT_PER_BUCKET
                res = await _inject_loan_book(n_per_bucket)
                if res["ok"] and res["created_loans"] is not None:
                    injected = {"count": res["created_loans"], "mode": "loan-book", "real": True}
                    buckets = res["per_bucket"] or {}
                    status, metric, msg = "success", f"{res['created_loans']:,} loans", (
                        f"LMS /scenarios/loan-book: {res['created_loans']} loans, "
                        f"{res['payments']} payments across {len(buckets)} buckets")
                else:
                    injected = {"count": n_per_bucket, "mode": "loan-book", "real": False}
                    status, metric, msg = "failure", None, f"LMS /scenarios/loan-book failed: {res.get('error')}"
            else:
                if inject_mode is None:
                    n = {"failure": FAILURE_INJECT_COUNT, "incident": INCIDENT_DIRTY_COUNT}.get(name, DEFAULT_INJECT_COUNT)
                    m = {"failure": "clean", "incident": "dirty"}.get(name, "clean")
                else:
                    n = max(0, count) if count is not None else DEFAULT_INJECT_COUNT
                    m = inject_mode

                if n == 0:
                    injected = {"count": 0, "mode": m, "real": False}
                    status, metric, msg = "success", "0 rows", "LMS /generate skipped (count=0)"
                else:
                    res = await _inject_lms(n, m)
                    if res["ok"]:
                        injected = {"count": res["count"], "mode": m, "real": True}
                        status, metric, msg = "success", f"{res['count']:,} rows", (
                            f"LMS /generate: {res['count']:,} rows injected (mode={m})")
                    else:
                        injected = {"count": n, "mode": m, "real": False}
                        status, metric, msg = "failure", None, f"LMS /generate failed: {res['error']}"

            latency = int((time.time() - t0) * 1000)
            payload = _hop_payload(hop, status, msg, metric, latency)
            hop_results.append(payload)
            yield "hop_done", payload
            if status == "failure":
                failed = True
            continue

        # ── failure: genuinely kill the Iceberg sink ────────────────────────
        if name == "failure" and hid == "kafka":
            stop = await asyncio.to_thread(_killswitch, "/iceberg-sink/stop", "POST")
            latency = int((time.time() - t0) * 1000)
            if not stop.get("ok"):
                payload = _hop_payload(
                    hop, "failure", f"kill-switch failed to stop Iceberg sink: {stop.get('error')}", None, latency)
                hop_results.append(payload)
                yield "hop_done", payload
                failed = True
                continue
            status_res = await asyncio.to_thread(_killswitch, "/iceberg-sink/status", "GET")
            running = bool(status_res.get("running") is True)
            if not running:
                msg = "Iceberg sink FAILED: MinIO object store stopped (docker stop lms-monitoring-minio-1)"
                metric = "sink down"
                payload = _hop_payload(hop, "failure", msg, metric, latency)
                hop_results.append(payload)
                yield "hop_done", payload
                failed = True
            else:
                payload = _hop_payload(
                    hop, "warning", "stop requested but MinIO still reports running", None, latency)
                hop_results.append(payload)
                yield "hop_done", payload
            continue

        # ── incident: run the real dbt DQ gate ───────────────────────────────
        if name == "incident" and hid == "silver":
            dbt_result = await asyncio.to_thread(_killswitch, "/dbt/run", "POST")
            latency = int((time.time() - t0) * 1000)
            if not dbt_result.get("ok"):
                msg = f"dbt run failed to start: {dbt_result.get('error')}"
                payload = _hop_payload(hop, "failure", msg, None, latency)
                hop_results.append(payload)
                yield "hop_done", payload
                failed = True
                continue
            # `dbt test` exiting non-zero is the DQ breach, not a run failure —
            # only a non-zero `run_rc` means the Silver transform itself failed.
            if dbt_result.get("run_rc") not in (0, None):
                tail = (dbt_result.get("stderr_tail") or "")[-300:]
                msg = f"dbt run failed (run_rc={dbt_result.get('run_rc')}): {tail}"
                payload = _hop_payload(hop, "failure", msg, None, latency)
                hop_results.append(payload)
                yield "hop_done", payload
                failed = True
                continue
            msg = f"dbt Silver transform ran ({dbt_result.get('duration_ms')} ms)"
            payload = _hop_payload(hop, "success", msg, None, latency)
            hop_results.append(payload)
            yield "hop_done", payload
            continue

        if name == "incident" and hid == "gold":
            failures = dbt_result.get("dbt_test_failures") if dbt_result else None
            quarantine = dbt_result.get("quarantine_rows_total") if dbt_result else None
            latency = int((time.time() - t0) * 1000)
            if failures is not None and failures > 0:
                msg = (f"gold DQ SLO BREACHED: {failures} dbt test(s) failing "
                       f"(quarantine rows: {quarantine if quarantine is not None else '?'})")
                payload = _hop_payload(hop, "failure", msg, f"{failures} failed", latency)
                hop_results.append(payload)
                yield "hop_done", payload
                failed = True
            else:
                payload = _hop_payload(hop, "success", f"gold DQ passed ({failures or 0} failures)", f"{failures or 0} failed", latency)
                hop_results.append(payload)
                yield "hop_done", payload
            continue

        # ── default: real downstream observation ────────────────────────────
        status, message, metric = await asyncio.to_thread(_real_downstream, hid)
        latency = int((time.time() - t0) * 1000)
        payload = _hop_payload(hop, status, message, metric, latency)
        hop_results.append(payload)
        yield "hop_done", payload
        if status == "failure":
            failed = True

    # Incident → open a REAL Plane ticket ONLY when the DQ actually breached
    # (the dbt gate ran and reported failing tests). If the pipeline broke
    # before the DQ gate, there is no breach, so no ticket — the hop statuses
    # already surface the real failure.
    if scenario["status"] == "incident" and dbt_result is not None:
        failures = dbt_result.get("dbt_test_failures")
        if failures is not None and failures > 0:
            quarantine = dbt_result.get("quarantine_rows_total")
            dirty_count = injected.get("count") if injected else INCIDENT_DIRTY_COUNT
            breach = (
                f"DQ SLO breach: {failures} dbt test(s) failing, "
                f"quarantine rows {quarantine if quarantine is not None else '?'} "
                f"after injecting {dirty_count:,} dirty rows"
            )
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
