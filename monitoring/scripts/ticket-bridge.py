#!/usr/bin/env python3
"""Alertmanager -> Plane incident ticket bridge.

Listens for Alertmanager webhook notifications (POST /alerts) and opens one
Plane issue per *firing* alert, deduped in-process so repeated/grouped
notifications don't spam the board. Resolved alerts are logged only.

Stdlib only — no third-party dependencies, so it runs in `python:3.12-slim`.

Configuration (env):
    PLANE_API_URL      Plane API base, e.g. http://plane:8000/api/v1
                       (default http://plane:8000/api/v1)
    PLANE_API_KEY      Workspace API key (sent as the X-API-Key header) — REQUIRED
    PLANE_WORKSPACE    Workspace slug — REQUIRED
    PLANE_PROJECT_ID   Project UUID to receive incidents — REQUIRED
    PLANE_UI_URL       UI base for the ticket link (default http://localhost:3010)
    BRIDGE_PORT        Listen port (default 8001)
    BRIDGE_DEDUPE_TTL  Seconds to suppress duplicate tickets (default 3600)
    BRIDGE_DRY_RUN     If "1"/"true"/"yes", log instead of POSTing to Plane

Endpoints:
    GET  /health       200 liveness probe
    POST /alerts       Alertmanager webhook payload
"""
import hashlib
import json
import os
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Optional
from urllib import error, request

PLANE_API_URL = os.environ.get("PLANE_API_URL", "http://plane:8000/api/v1").rstrip("/")
PLANE_API_KEY = os.environ.get("PLANE_API_KEY", "")
PLANE_WORKSPACE = os.environ.get("PLANE_WORKSPACE", "")
PLANE_PROJECT_ID = os.environ.get("PLANE_PROJECT_ID", "")
PLANE_UI_URL = os.environ.get("PLANE_UI_URL", "http://localhost:3010").rstrip("/")
BRIDGE_PORT = int(os.environ.get("BRIDGE_PORT", "8001"))
DEDUPE_TTL = int(os.environ.get("BRIDGE_DEDUPE_TTL", "3600"))
DRY_RUN = os.environ.get("BRIDGE_DRY_RUN", "").strip().lower() in ("1", "true", "yes")

# Alertmanager `severity` -> Plane issue `priority`.
PRIORITY_MAP = {
    "critical": "urgent",
    "error": "high",
    "warning": "high",
    "page": "urgent",
    "info": "low",
}

_seen = {}
_lock = threading.Lock()


def configured() -> bool:
    return all((PLANE_API_KEY, PLANE_WORKSPACE, PLANE_PROJECT_ID))


def fingerprint(alert: dict) -> str:
    """Identity of an alert = alertname + all non-ephemeral labels."""
    labels = alert.get("labels", {})
    keys = sorted(k for k in labels if k != "alertname")
    sig = labels.get("alertname", "") + "|" + "|".join(f"{k}={labels[k]}" for k in keys)
    return hashlib.sha256(sig.encode()).hexdigest()[:16]


def is_duplicate(fp: str) -> bool:
    now = time.time()
    with _lock:
        last = _seen.get(fp)
        if last is not None and now - last < DEDUPE_TTL:
            return True
        _seen[fp] = now
        return False


def create_issue(alert: dict) -> Optional[str]:
    labels = alert.get("labels", {})
    annotations = alert.get("annotations", {})
    alertname = labels.get("alertname", "alert")
    summary = annotations.get("summary") or alertname
    severity = labels.get("severity", "warning")

    title = f"[Monitoring] {alertname}: {summary}"[:255]
    parts = [
        f"<p><b>Status:</b> {alert.get('status', 'unknown')}</p>",
        f"<p><b>Severity:</b> {severity}</p>",
    ]
    if alert.get("startsAt"):
        parts.append(f"<p><b>Starts:</b> {alert['startsAt']}</p>")
    if annotations.get("description"):
        parts.append(f"<p>{annotations['description']}</p>")
    if labels:
        parts.append(
            "<p><b>Labels:</b><br/>"
            + "<br/>".join(f"{k}={v}" for k, v in sorted(labels.items()))
            + "</p>"
        )
    if alert.get("generatorURL"):
        parts.append(f'<p><a href="{alert["generatorURL"]}">Prometheus query</a></p>')
    payload = {
        "name": title,
        "description_html": "".join(parts),
        "priority": PRIORITY_MAP.get(severity, "medium"),
    }

    url = f"{PLANE_API_URL}/workspaces/{PLANE_WORKSPACE}/projects/{PLANE_PROJECT_ID}/issues/"
    req = request.Request(
        url,
        data=json.dumps(payload).encode(),
        headers={"Content-Type": "application/json", "X-API-Key": PLANE_API_KEY},
        method="POST",
    )
    if DRY_RUN:
        print(f"[dry-run] POST {url} -> {json.dumps(payload)}")
        return None

    with request.urlopen(req, timeout=15) as resp:
        body = json.loads(resp.read().decode() or "{}")
    issue_id = body.get("id")
    link = f"{PLANE_UI_URL}/{PLANE_WORKSPACE}/projects/{PLANE_PROJECT_ID}/issues/{issue_id}"
    print(f"[ticket] {alertname} -> issue {issue_id} ({link})")
    return issue_id


class BridgeHandler(BaseHTTPRequestHandler):
    server_version = "ticket-bridge/1.0"

    def _send_json(self, code: int, obj: dict) -> None:
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):  # noqa: N802
        if self.path in ("/health", "/healthz"):
            self._send_json(200, {"status": "ok", "configured": configured()})
        else:
            self._send_json(
                200,
                {
                    "status": "ok",
                    "service": "ticket-bridge",
                    "endpoints": ["POST /alerts", "GET /health"],
                },
            )

    def do_POST(self):  # noqa: N802
        if self.path not in ("/alerts", "/alert", "/"):
            self._send_json(404, {"error": "not found"})
            return
        length = int(self.headers.get("Content-Length", "0") or 0)
        raw = self.rfile.read(length)
        try:
            hook = json.loads(raw.decode() or "{}")
        except json.JSONDecodeError:
            self._send_json(400, {"error": "invalid JSON"})
            return
        if not configured():
            self._send_json(
                500,
                {"error": "PLANE_API_KEY / PLANE_WORKSPACE / PLANE_PROJECT_ID not set"},
            )
            return

        created, skipped, resolved, errors = [], 0, 0, []
        for alert in hook.get("alerts", []):
            status = alert.get("status", "")
            fp = fingerprint(alert)
            if status == "resolved":
                resolved += 1
                continue
            if status != "firing":
                skipped += 1
                continue
            if is_duplicate(fp):
                skipped += 1
                continue
            try:
                issue_id = create_issue(alert)
                created.append({"fingerprint": fp, "issue_id": issue_id})
            except error.HTTPError as exc:
                errors.append(f"{fp}: HTTP {exc.code} {exc.read().decode()[:200]}")
            except Exception as exc:  # noqa: BLE001
                errors.append(f"{fp}: {exc}")

        # 502 only when the whole batch failed (so Alertmanager retries); partial
        # failures still 200 — dedupe + repeat_interval cover the rest.
        self._send_json(
            502 if errors and not created and not resolved else 200,
            {
                "received": len(hook.get("alerts", [])),
                "created": created,
                "skipped": skipped,
                "resolved": resolved,
                "errors": errors,
            },
        )

    def log_message(self, format, *args):  # noqa: A002
        print(f"[{time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())}] {format % args}")


def main():
    server = ThreadingHTTPServer(("0.0.0.0", BRIDGE_PORT), BridgeHandler)
    print(
        f"ticket-bridge listening on :{BRIDGE_PORT} "
        f"(configured={configured()}, dry_run={DRY_RUN})"
    )
    if not configured():
        print("WARNING: PLANE_API_KEY / PLANE_WORKSPACE / PLANE_PROJECT_ID not set — "
              "/alerts will return 500 until configured.")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
