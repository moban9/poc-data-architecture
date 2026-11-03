#!/usr/bin/env python3
"""Kafka consumer-group lag exporter sidecar (Relay).

Runs `kafka-consumer-groups.sh --describe --all-groups` on an interval, sums the
per-partition LAG into a per-(group, topic) gauge and serves it in Prometheus
text format. Scraped by Prometheus (job `kafka-lag-exporter`).

Exposes: kafka_consumergroup_lag{group=..., topic=...}  <sum of partition lags>
"""
import os
import subprocess
import threading
import time
from collections import defaultdict
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

BOOTSTRAP = os.environ.get("BOOTSTRAP_SERVERS", "kafka:9092")
INTERVAL = int(os.environ.get("SCRAPE_INTERVAL", "10"))
PORT = int(os.environ.get("EXPORTER_PORT", "9190"))
CLI = os.environ.get("KAFKA_CONSUMER_GROUPS", "/kafka/bin/kafka-consumer-groups.sh")

_lock = threading.Lock()
_latest = (
    b"# HELP kafka_consumergroup_lag Consumer group lag per topic "
    b"(sum over partitions)\n# TYPE kafka_consumergroup_lag gauge\n"
)


def _esc(v: str) -> str:
    return v.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")


def collect():
    global _latest
    cmd = [CLI, "--bootstrap-server", BOOTSTRAP, "--describe", "--all-groups"]
    try:
        out = subprocess.run(cmd, capture_output=True, text=True, timeout=60).stdout
    except Exception:
        with _lock:
            _latest = (
                b"# HELP kafka_consumergroup_lag_export_error 1 if the last export failed\n"
                b"# TYPE kafka_consumergroup_lag_export_error gauge\n"
                b"kafka_consumergroup_lag_export_error 1\n"
            )
        return

    agg = defaultdict(int)
    for line in out.splitlines():
        parts = line.split()
        if len(parts) < 6:
            continue
        group, topic = parts[0], parts[1]
        if group == "GROUP" or not parts[2].isdigit():
            continue  # header row or malformed row
        try:
            lag = int(parts[5])
        except ValueError:
            continue
        agg[(group, topic)] += lag

    body = [
        "# HELP kafka_consumergroup_lag Consumer group lag per topic (sum over partitions)",
        "# TYPE kafka_consumergroup_lag gauge",
    ]
    for (group, topic) in sorted(agg):
        body.append(
            f'kafka_consumergroup_lag{{group="{_esc(group)}",topic="{_esc(topic)}"}} '
            f"{agg[(group, topic)]}"
        )
    body.append("")
    with _lock:
        _latest = ("\n".join(body)).encode()


def loop():
    while True:
        collect()
        time.sleep(INTERVAL)


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/metrics":
            with _lock:
                body = _latest
            self.send_response(200)
            self.send_header("Content-Type", "text/plain; version=0.0.4")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        else:
            self.send_response(404)
            self.end_headers()

    def log_message(self, format, *args):
        pass


if __name__ == "__main__":
    collect()
    threading.Thread(target=loop, daemon=True).start()
    ThreadingHTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
