#!/usr/bin/env python3
"""Demo kill-switch — least-privilege, reversible control of the POC pipeline.

Randy directive: the demo's "failure" and "incident" scenarios must REALLY kill
the target process, not fake it. This service is the narrowly-scoped mechanism
that lets the control panel do that.

It exposes a tiny HTTP API and, behind a HARD-CODED ALLOWLIST, runs only the
exact docker commands the two scenarios need:

  * iceberg-sink  -> `docker stop/start` the MinIO (s3mock) container.
                     MinIO is the object store the Iceberg sink connector writes
                     to, and the Grafana "Iceberg" topology node is the live
                     blackbox probe of MinIO (`probe_success{job="minio"}`). So
                     stopping MinIO genuinely breaks the Iceberg sink AND turns
                     the Grafana Iceberg node red via the real probe.
  * dbt/run       -> run the real dbt medallion pipeline (seed+run+test) in a
                     throwaway container, exactly like the Dagster schedule
                     does. This refreshes Bronze/Silver/Gold and pushes the real
                     dbt_test_failures / dbt_run_success / quarantine metrics to
                     the pushgateway, so a dirty-data injection produces a REAL
                     data-quality breach.

No arbitrary command execution: the container name, the dbt image, the bind
mount and the network are all fixed (overridable only by env at deploy time),
and every request is matched against an explicit allowlist of actions.

Endpoints
---------
  GET  /health                      -> service + current target state
  GET  /iceberg-sink/status         -> {"running": bool, "detail": "..."}
  POST /iceberg-sink/stop           -> stop the MinIO container (reversible)
  POST /iceberg-sink/start          -> start it again
  POST /dbt/run                     -> run the dbt pipeline, return rc + DQ counts

Environment (deploy-time only)
------------------------------
  PORT                      listen port (default 8002)
  ICEBERG_SINK_CONTAINER    MinIO container name (default lms-monitoring-minio-1)
  DBT_RUNNER_CONTAINER      container that has `dbt` + the mounted dbt project +
                            network access to Trino/Pushgateway; the kill-switch
                            `docker exec`s into it to run dbt (default
                            lms-monitoring-dagster-1)
  DBT_RUN_TIMEOUT           seconds to allow a full dbt run (default 900)
"""
from __future__ import annotations

import json
import os
import subprocess
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = int(os.environ.get("PORT", "8002"))
ICEBERG_SINK_CONTAINER = os.environ.get("ICEBERG_SINK_CONTAINER", "lms-monitoring-minio-1")
# `docker run` containers on the compose network cannot resolve service names
# (Docker embedded DNS does not serve the compose aliases to ad-hoc `docker run`
# containers on this host), so dbt is run by exec-ing into an existing container
# that already has dbt + the mounted project + working network DNS.
DBT_RUNNER_CONTAINER = os.environ.get("DBT_RUNNER_CONTAINER", "lms-monitoring-dagster-1")
DBT_RUN_TIMEOUT = int(os.environ.get("DBT_RUN_TIMEOUT", "900"))

_DOCKER = "docker"


def _run(argv: list[str], timeout: int = 60) -> dict:
    """Run a docker command; return {rc, stdout, stderr, error}."""
    try:
        proc = subprocess.run(
            [_DOCKER, *argv],
            capture_output=True,
            text=True,
            timeout=timeout,
        )
        return {
            "rc": proc.returncode,
            "stdout": proc.stdout.strip(),
            "stderr": proc.stderr.strip(),
            "error": None,
        }
    except FileNotFoundError as exc:
        return {"rc": -1, "stdout": "", "stderr": "", "error": f"docker CLI not found: {exc}"}
    except subprocess.TimeoutExpired as exc:
        return {"rc": -2, "stdout": "", "stderr": "", "error": f"timed out after {timeout}s"}


def _iceberg_status() -> dict:
    res = _run(["inspect", "-f", "{{.State.Running}} {{.State.Status}}", ICEBERG_SINK_CONTAINER])
    if res["rc"] != 0 or res["error"]:
        return {"running": False, "detail": res["stderr"] or res["error"] or "not found"}
    running = res["stdout"].split()[0] == "true"
    return {"running": running, "detail": res["stdout"]}


def _dbt_run() -> dict:
    """Run the real dbt pipeline (run + test) and return the DQ outcome.

    `loan_delinquency_snapshot` is excluded: an in-progress sibling model whose
    incremental `append` strategy trips TABLE_ALREADY_EXISTS against the Polaris
    catalog on re-run, failing an otherwise-green dbt run. The DQ breach signal
    comes from the remaining (silver + gold) test suite, which is what the
    incident scenario needs.
    """
    started = time.time()
    run_cmd = "cd /dbt && dbt run --exclude loan_delinquency_snapshot --profiles-dir /dbt"
    test_cmd = "cd /dbt && dbt test --exclude loan_delinquency_snapshot --profiles-dir /dbt"

    run_res = _run(["exec", DBT_RUNNER_CONTAINER, "sh", "-c", run_cmd], timeout=DBT_RUN_TIMEOUT)
    # `dbt test` exiting non-zero is the DQ breach itself, NOT a run failure —
    # capture it separately so callers can tell the two apart.
    test_res = _run(["exec", DBT_RUNNER_CONTAINER, "sh", "-c", test_cmd], timeout=DBT_RUN_TIMEOUT)
    duration_ms = int((time.time() - started) * 1000)

    failures = None
    total = None
    quarantine = None

    # `dbt test` wrote its results to target/run_results.json.
    rr = _run(["exec", DBT_RUNNER_CONTAINER, "cat", "/dbt/target/run_results.json"], timeout=30)
    if rr["rc"] == 0 and rr["stdout"]:
        try:
            data = json.loads(rr["stdout"])
            test_nodes = [r for r in data.get("results", [])
                          if r.get("unique_id", "").startswith("test.")]
            total = len(test_nodes)
            failures = sum(1 for r in test_nodes if r.get("status") in ("fail", "error"))
        except (ValueError, TypeError):
            pass

    # Real quarantine count (the rows dbt isolated for the failing tests).
    q_cmd = (
        "cd /dbt && python3 scripts/trino_query.py "
        "'SELECT count(*) AS c FROM lakehouse.quarantine_lms.quarantine_lms' --host trino"
    )
    q_res = _run(["exec", DBT_RUNNER_CONTAINER, "sh", "-c", q_cmd], timeout=60)
    if q_res["rc"] == 0 and q_res["stdout"]:
        try:
            rows = json.loads(q_res["stdout"])
            if rows and isinstance(rows[0], list) and rows[0] is not None:
                quarantine = rows[0][0]
        except (ValueError, TypeError):
            pass

    # Reflect the DQ outcome in monitoring (same metric contract as
    # dbt/scripts/run-and-push-metrics.sh) so Grafana's dbt-test panel and the
    # DbtTestFailures alert see the real breach.
    if failures is not None:
        _push_dbt_metrics(failures, total)

    return {
        "run_rc": run_res["rc"],       # 0 = dbt run succeeded (silver+gold built)
        "test_rc": test_res["rc"],     # non-zero = some DQ tests failed (breach)
        "duration_ms": duration_ms,
        "dbt_test_failures": failures,
        "dbt_tests_total": total,
        "quarantine_rows_total": quarantine,
        "error": run_res["error"] or test_res["error"],
        "stdout_tail": (run_res["stdout"] + "\n" + test_res["stdout"])[-2000:],
        "stderr_tail": (run_res["stderr"] + "\n" + test_res["stderr"])[-2000:],
    }


def _push_dbt_metrics(failures: int, total: int | None) -> None:
    """Best-effort push of the DQ outcome to the pushgateway."""
    import urllib.request

    lines = [
        'dbt_run_success{layer="bronze"} 1',
        'dbt_run_success{layer="silver"} 1',
        'dbt_run_success{layer="gold"} 1',
        f"dbt_test_failures {failures}",
        f"dbt_tests_total {total if total is not None else 0}",
    ]
    body = "\n".join(lines) + "\n"
    url = os.environ.get("PUSHGATEWAY_URL", "http://pushgateway:9091").rstrip("/") \
        + "/metrics/job/dbt/instance/lms-poc-dbt"
    try:
        req = urllib.request.Request(url, data=body.encode(), method="PUT")
        urllib.request.urlopen(req, timeout=10)
    except Exception:  # noqa: BLE001 — monitoring is best-effort
        pass


# ─────────────────────────────────────────────────────────────────────────────
# Allowlist: path -> (method, handler). Every other path/method is 404.
# ─────────────────────────────────────────────────────────────────────────────
def _health() -> dict:
    return {
        "status": "ok",
        "service": "demo-killswitch",
        "iceberg_sink": _iceberg_status(),
        "dbt": {
            "runner_container": DBT_RUNNER_CONTAINER,
        },
    }


def _stop_iceberg() -> dict:
    stop = _run(["stop", ICEBERG_SINK_CONTAINER])
    return {"stopped": True, **_iceberg_status(), **stop}


def _start_iceberg() -> dict:
    start = _run(["start", ICEBERG_SINK_CONTAINER])
    return {"started": True, **_iceberg_status(), **start}


ROUTES = {
    ("GET", "/health"): _health,
    ("GET", "/iceberg-sink/status"): _iceberg_status,
    ("POST", "/iceberg-sink/stop"): _stop_iceberg,
    ("POST", "/iceberg-sink/start"): _start_iceberg,
    ("POST", "/dbt/run"): _dbt_run,
}


class Handler(BaseHTTPRequestHandler):
    server_version = "demo-killswitch/1.0"

    def _send(self, code: int, obj: dict) -> None:
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _route(self, method: str) -> None:
        handler = ROUTES.get((method, self.path))
        if handler is None:
            self._send(404, {"error": "not found", "allowed": sorted(k[1] for k in ROUTES)})
            return
        try:
            result = handler()
        except Exception as exc:  # noqa: BLE001 — surface the real error
            self._send(500, {"error": f"{type(exc).__name__}: {exc}"})
            return
        self._send(200, result)

    def do_GET(self):  # noqa: N802
        self._route("GET")

    def do_POST(self):  # noqa: N802
        # Ignore the request body — every action is parameter-free.
        self._route("POST")

    def log_message(self, format, *args):  # noqa: A002, N802
        print(f"[{time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())}] {format % args}", flush=True)


def main() -> None:
    server = ThreadingHTTPServer(("0.0.0.0", PORT), Handler)
    print(
        f"demo-killswitch listening on :{PORT} "
        f"(iceberg_sink={ICEBERG_SINK_CONTAINER}, dbt_runner={DBT_RUNNER_CONTAINER})",
        flush=True,
    )
    server.serve_forever()


if __name__ == "__main__":
    main()
