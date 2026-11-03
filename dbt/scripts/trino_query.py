#!/usr/bin/env python3
"""Minimal Trino HTTP-API query helper (stdlib only).

The `trino` CLI in this stack is broken (JMX javaagent port conflict), so all
ad-hoc queries go through the Trino HTTP API instead: POST /v1/statement and
poll nextUri until `data` is present, accumulating rows across pages.

Usage:
    python3 trino_query.py "SELECT ..." [--host trino] [--port 8080] \
        [--catalog lakehouse] [--schema bronze] [--user meridian]

Prints the combined rows as a JSON array on stdout. Exits 2 on a query error.
"""
import json
import os
import sys
import urllib.request


def run(sql, host=None, port=8080, catalog="lakehouse", schema="bronze", user="meridian"):
    host = host or os.environ.get("TRINO_HOST", "trino")
    base = f"http://{host}:{port}/v1/statement"
    headers = {
        "X-Trino-User": user,
        "X-Trino-Catalog": catalog,
        "X-Trino-Schema": schema,
        "Content-Type": "text/plain",
    }
    req = urllib.request.Request(base, data=sql.encode("utf-8"), headers=headers, method="POST")
    body = json.load(urllib.request.urlopen(req, timeout=120))
    rows = []
    while True:
        data = body.get("data")
        if data:
            rows.extend(data)
        nxt = body.get("nextUri")
        if not nxt:
            break
        req = urllib.request.Request(nxt, headers={"X-Trino-User": user})
        body = json.load(urllib.request.urlopen(req, timeout=120))
    err = body.get("error")
    if err:
        print(json.dumps({"error": err.get("message", str(err))}))
        sys.exit(2)
    return rows


def _opts(argv):
    opts = {}
    i = 0
    args = []
    while i < len(argv):
        a = argv[i]
        if a.startswith("--") and i + 1 < len(argv):
            opts[a[2:]] = argv[i + 1]
            i += 2
        else:
            args.append(a)
            i += 1
    return args, opts


if __name__ == "__main__":
    args, opts = _opts(sys.argv[1:])
    if not args:
        print("usage: trino_query.py 'SQL' [--host H] [--port P] [--catalog C] [--schema S] [--user U]")
        sys.exit(1)
    rows = run(
        args[0],
        host=opts.get("host"),
        port=int(opts.get("port", 8080)),
        catalog=opts.get("catalog", "lakehouse"),
        schema=opts.get("schema", "bronze"),
        user=opts.get("user", "meridian"),
    )
    print(json.dumps(rows))
