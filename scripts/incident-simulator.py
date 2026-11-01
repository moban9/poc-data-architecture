#!/usr/bin/env python3
"""Incident simulator — fires a simulated incident and auto-creates a ticket in an
open-source ticketing engine (Plane, a Jira/Linear alternative) to demonstrate
automated incident management.

Usage:
    INCIDENT_TYPE="data-quality" INCIDENT_MSG="Gold freshness check failed" \
    python3 incident-simulator.py

Config via env (parameterized, defaults where sensible):
    PLANE_API_URL     base URL (default http://plane:8000/api/v1)
    PLANE_API_KEY     workspace API key
    PLANE_WORKSPACE   workspace slug
    PLANE_PROJECT_ID  project UUID
    PLANE_UI_URL      UI base (default http://plane:3000) for the printed link
    INCIDENT_TYPE     incident category (default "generic")
    INCIDENT_MSG      human description (default "Simulated incident")
"""
import os
import json
import urllib.request
import urllib.error


def main():
    base = os.environ.get("PLANE_API_URL", "http://plane:8000/api/v1").rstrip("/")
    key = os.environ.get("PLANE_API_KEY", "")
    ws = os.environ.get("PLANE_WORKSPACE", "")
    proj = os.environ.get("PLANE_PROJECT_ID", "")
    itype = os.environ.get("INCIDENT_TYPE", "generic")
    msg = os.environ.get("INCIDENT_MSG", "Simulated incident")

    if not (key and ws and proj):
        print("❌ missing PLANE_API_KEY / PLANE_WORKSPACE / PLANE_PROJECT_ID")
        raise SystemExit(1)

    payload = {
        "name": f"[INCIDENT] {itype}: {msg}",
        "description_html": (
            f"<p>Simulated incident fired by the POC incident simulator.</p>"
            f"<p><b>Type:</b> {itype}</p><p><b>Message:</b> {msg}</p>"
        ),
        "priority": "urgent",
    }
    url = f"{base}/workspaces/{ws}/projects/{proj}/issues/"
    req = urllib.request.Request(
        url,
        data=json.dumps(payload).encode(),
        headers={"Content-Type": "application/json", "X-API-Key": key},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=15) as r:
            resp = json.load(r)
    except urllib.error.HTTPError as e:
        print(f"❌ failed to create ticket: {e.code} {e.read().decode()[:300]}")
        raise SystemExit(1)

    ui = os.environ.get("PLANE_UI_URL", "http://plane:3000")
    link = f"{ui}/{ws}/projects/{proj}/issues/{resp.get('id')}"
    print(f"✅ incident ticket created — id {resp.get('id')}")
    print(f"   title: {resp.get('name')}")
    print(f"   link:  {link}")


if __name__ == "__main__":
    main()
