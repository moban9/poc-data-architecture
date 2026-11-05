#!/usr/bin/env python3
"""Provision the "LMS POC — Business Performance (Gold)" dashboard in Metabase.

Reads the card packs in ./sql/*.sql, creates/updates one native Trino question per
card (idempotent: matched by exact name), builds the dashboard layout, then runs
every card through Metabase's query API and reports how many rows each returned.

Python 3 stdlib only — no pip install, no jq, no curl wrapper.

Usage
-----
  export METABASE_USER='you@example.com'
  export METABASE_PASSWORD='…'
  python3 provision_metabase.py --dry-run          # parse + show plan, no writes
  python3 provision_metabase.py                    # create/update + verify
  python3 provision_metabase.py --base-url http://localhost:8085

Exit codes: 0 all cards created and non-empty · 1 provisioning error ·
            2 verification found an empty card · 3 dry-run completed.

WHAT IT DOES NOT DO: it never creates the Trino *database* connection unless you
pass --create-db (default off, because the connection is an operator decision —
docs/04-metabase.md §3). It never deletes cards or dashboards.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
import urllib.error
import urllib.request
from pathlib import Path

# --------------------------------------------------------------------------- #
# Card-pack parser
# --------------------------------------------------------------------------- #

HEADER_RE = re.compile(
    r'^--\s*===\s*card:\s*(?P<name>[^|]+?)\s*\|\s*display:\s*(?P<display>[A-Za-z]+)\s*'
    r'\|\s*size:\s*(?P<w>\d+)x(?P<h>\d+)\s*(?P<rest>.*?)===\s*$'
)

VALID_DISPLAY = {"scalar", "bar", "line", "table", "area", "row"}


def _parse_opts(rest: str) -> dict:
    """Parse `| x: col | y: a,b | fmt: a=percent,b=currency` into a dict."""
    opts: dict[str, str] = {}
    for chunk in rest.split("|"):
        chunk = chunk.strip()
        if not chunk or ":" not in chunk:
            continue
        key, _, value = chunk.partition(":")
        opts[key.strip().lower()] = value.strip()
    return opts


def load_cards(sql_dir: Path) -> list[dict]:
    cards: list[dict] = []
    for path in sorted(sql_dir.glob("*.sql")):
        current = None
        for line in path.read_text(encoding="utf-8").splitlines():
            m = HEADER_RE.match(line)
            if m:
                if current:
                    cards.append(current)
                opts = _parse_opts(m.group("rest"))
                current = {
                    "name": m.group("name").strip(),
                    "display": m.group("display").lower(),
                    "size_x": int(m.group("w")),
                    "size_y": int(m.group("h")),
                    "x": opts.get("x"),
                    "y": [c.strip() for c in opts["y"].split(",")] if opts.get("y") else [],
                    "fmt": {},
                    "section": path.stem.split("-", 1)[-1],
                    "source_file": path.name,
                    "sql": [],
                }
                for pair in filter(None, (p.strip() for p in opts.get("fmt", "").split(","))):
                    if "=" in pair:
                        col, style = pair.split("=", 1)
                        current["fmt"][col.strip()] = style.strip()
                continue
            if current is not None:
                current["sql"].append(line)
        if current:
            cards.append(current)

    for c in cards:
        # Trino's /v1/statement endpoint parses a single statement and rejects a
        # trailing `;` (the CLI strips it, the JDBC driver does not). The card
        # bodies use `;` as a human-readable terminator, so strip it before send.
        c["sql"] = re.sub(r";\s*$", "", "\n".join(c["sql"]).strip())
        if not c["sql"]:
            raise SystemExit(f"[parse] card '{c['name']}' has an empty query body")
        if c["display"] not in VALID_DISPLAY:
            raise SystemExit(f"[parse] card '{c['name']}' has unknown display '{c['display']}'")
    if not cards:
        raise SystemExit(f"[parse] no cards found in {sql_dir}")
    return cards


def viz_settings(card: dict) -> dict:
    vs: dict = {}
    if card["display"] in {"bar", "line", "area", "row"} and card["x"]:
        vs["graph.dimensions"] = [card["x"]]
        if card["y"]:
            vs["graph.metrics"] = card["y"]
    if card["display"] in {"bar", "line"}:
        vs.setdefault("graph.show_values", False)
    if card["fmt"]:
        cs = {}
        for col, style in card["fmt"].items():
            entry: dict = {"number_style": style}
            if style in {"currency", "percent"}:
                entry["decimals"] = 2
            cs[json.dumps(["name", col])] = entry
        vs["column_settings"] = cs
    return vs


# --------------------------------------------------------------------------- #
# Metabase API client
# --------------------------------------------------------------------------- #

class Metabase:
    def __init__(self, base_url: str, token: str | None = None, verbose: bool = True):
        self.base = base_url.rstrip("/")
        self.token = token
        self.verbose = verbose

    def request(self, method: str, path: str, payload=None, raw: bool = False):
        url = f"{self.base}{path}"
        body = json.dumps(payload).encode() if payload is not None else None
        headers = {"Accept": "application/json"}
        if body is not None:
            headers["Content-Type"] = "application/json"
        if self.token:
            headers["X-Metabase-Session"] = self.token
        req = urllib.request.Request(url, data=body, headers=headers, method=method)
        try:
            with urllib.request.urlopen(req, timeout=120) as resp:
                data = resp.read()
                return resp.status, (data if raw else (json.loads(data) if data else None))
        except urllib.error.HTTPError as exc:
            detail = exc.read().decode("utf-8", "replace")[:800]
            raise RuntimeError(f"{method} {path} -> HTTP {exc.code}: {detail}") from exc
        except urllib.error.URLError as exc:
            raise RuntimeError(f"{method} {path} -> unreachable: {exc.reason}") from exc

    def login(self, user: str, password: str) -> None:
        status, body = self.request("POST", "/api/session", {"username": user, "password": password})
        token = (body or {}).get("id")
        if status != 200 or not token:
            raise RuntimeError(f"login failed (HTTP {status}); check METABASE_USER / METABASE_PASSWORD")
        self.token = token

    def find_database(self, name: str):
        _, body = self.request("GET", "/api/database")
        items = (body or {}).get("data") or (body or {}).get("databases") or []
        for db in items:
            if str(db.get("name", "")).lower() == name.lower():
                return db
        return None

    def list_cards(self) -> list[dict]:
        for path in ("/api/card?f=all", "/api/card"):
            try:
                _, body = self.request("GET", path)
            except RuntimeError:
                continue
            if isinstance(body, list):
                return body
            if isinstance(body, dict):
                for key in ("data", "cards"):
                    if isinstance(body.get(key), list):
                        return body[key]
        return []

    def list_dashboards(self) -> list[dict]:
        for path in ("/api/dashboard", "/api/dashboard?f=all"):
            try:
                _, body = self.request("GET", path)
            except RuntimeError:
                continue
            if isinstance(body, list):
                return body
            if isinstance(body, dict):
                for key in ("data", "dashboards"):
                    if isinstance(body.get(key), list):
                        return body[key]
        return []


# --------------------------------------------------------------------------- #
# Layout
# --------------------------------------------------------------------------- #

GRID_WIDTH = 24


def pack_layout(cards: list[dict]) -> list[dict]:
    """Simple shelf packer: place cards left-to-right, wrap when the row is full."""
    placed, col, row, shelf_h = [], 0, 0, 0
    for c in cards:
        w = min(c["size_x"], GRID_WIDTH)
        h = c["size_y"]
        if col + w > GRID_WIDTH:
            row += shelf_h
            col, shelf_h = 0, 0
        placed.append({**c, "col": col, "row": row})
        col += w
        shelf_h = max(shelf_h, h)
    return placed


# --------------------------------------------------------------------------- #
# Main
# --------------------------------------------------------------------------- #

def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--base-url", default=os.environ.get("METABASE_URL", "https://bi.onendo.cloud"))
    ap.add_argument("--user", default=os.environ.get("METABASE_USER"))
    ap.add_argument("--password", default=os.environ.get("METABASE_PASSWORD"))
    ap.add_argument("--database-name", default="Lakehouse")
    ap.add_argument("--dashboard-name", default="LMS POC — Business Performance (Gold)")
    ap.add_argument("--description",
                    default="Portfolio health, NPL/delinquency, payments and data quality from the "
                            "gold layer (Trino → lakehouse.gold.*). Built by Prism; reviewed by Atlas.")
    ap.add_argument("--collection-id", type=int, default=None,
                    help="target collection id (default: root collection)")
    ap.add_argument("--sql-dir", default=str(Path(__file__).resolve().parent / "sql"))
    ap.add_argument("--dry-run", action="store_true", help="parse and print the plan only")
    ap.add_argument("--create-db", action="store_true",
                    help="create the Trino connection if the named database is missing")
    ap.add_argument("--no-verify", action="store_true", help="skip the post-provision row-count check")
    args = ap.parse_args()

    cards = pack_layout(load_cards(Path(args.sql_dir)))
    print(f"[parse] {len(cards)} cards from {args.sql_dir}")
    for c in cards:
        print(f"  · {c['name']:<55} {c['display']:<7} {c['size_x']}x{c['size_y']}  <- {c['source_file']}")

    if args.dry_run:
        print("\n[dry-run] no changes written")
        return 3

    if not args.user or not args.password:
        raise SystemExit("missing credentials: set METABASE_USER and METABASE_PASSWORD "
                         "(or pass --user/--password). The admin account was created in the UI.")

    mb = Metabase(args.base_url)
    mb.login(args.user, args.password)
    print(f"[auth] session established against {args.base_url}")

    db = mb.find_database(args.database_name)
    if db is None:
        if not args.create_db:
            raise SystemExit(
                f"[db] no Metabase database named '{args.database_name}'. Create it first "
                f"(docs/04-metabase.md §3: type Starburst (Trino), host trino, port 8080, catalog lakehouse, "
                f"schema gold), or re-run with --create-db."
            )
        _, db = mb.request("POST", "/api/database", {
            "name": args.database_name,
            "engine": "starburst",
            "details": {"host": "trino", "port": 8080, "user": "trino", "password": "",
                        "ssl": False, "catalog": "lakehouse", "schema": "gold"},
        })
        db = db or {}
        print(f"[db] created Trino connection id={db.get('id')}")
    db_id = (db or {}).get("id")
    if not db_id:
        raise SystemExit("[db] Metabase returned no database id — check the Trino connection by hand")
    print(f"[db] using database '{db.get('name')}' id={db_id}")

    existing_cards = {c.get("name"): c.get("id") for c in mb.list_cards()}
    card_ids: list[tuple[dict, int]] = []
    for c in cards:
        query = {
            "database": db_id,
            "type": "native",
            "native": {"query": c["sql"], "template-tags": {}},
        }
        payload = {
            "name": c["name"],
            "display": c["display"],
            "dataset_query": query,
            "visualization_settings": viz_settings(c),
            "collection_id": args.collection_id,
            "description": f"Source: {c['source_file']} · definition in metric_definitions.md",
        }
        if c["name"] in existing_cards and existing_cards[c["name"]]:
            cid = existing_cards[c["name"]]
            mb.request("PUT", f"/api/card/{cid}", payload)
            print(f"[card] updated  {cid:>4}  {c['name']}")
        else:
            _, created = mb.request("POST", "/api/card", payload)
            cid = (created or {}).get("id")
            if not cid:
                raise SystemExit(f"[card] Metabase returned no id for '{c['name']}' — response was: {created!r}")
            print(f"[card] created  {cid:>4}  {c['name']}")
        card_ids.append((c, cid))

    dash = next((d for d in mb.list_dashboards() if d.get("name") == args.dashboard_name), None)
    if dash:
        dash_id = dash.get("id")
        print(f"[dash] found    {dash_id}  {args.dashboard_name}")
    else:
        _, dash = mb.request("POST", "/api/dashboard", {
            "name": args.dashboard_name,
            "description": args.description,
            "collection_id": args.collection_id,
        })
        dash = dash or {}
        dash_id = dash.get("id")
        print(f"[dash] created  {dash_id}  {args.dashboard_name}")

    dashcards = []
    for idx, (c, cid) in enumerate(card_ids, start=1):
        dashcards.append({
            "id": -idx,             # negative id = "new dashcard" in the modern dashboard API
            "card_id": cid,
            "row": c["row"],
            "col": c["col"],
            "size_x": c["size_x"],
            "size_y": c["size_y"],
            "parameter_mappings": [],
            "series": [],
            "visualization_settings": {},
        })

    try:
        mb.request("PUT", f"/api/dashboard/{dash_id}", {
            "name": args.dashboard_name,
            "description": args.description,
            "dashcards": dashcards,
        })
        print(f"[dash] layout applied ({len(dashcards)} cards)")
    except RuntimeError as exc:
        print(f"[dash] modern dashcards API failed: {exc}", file=sys.stderr)
        print("[dash] fall back to the legacy per-card endpoint, one card at a time…", file=sys.stderr)
        for dc in dashcards:
            try:
                mb.request("POST", f"/api/dashboard/{dash_id}/cards", {
                    "cardId": dc["card_id"], "row": dc["row"], "col": dc["col"],
                    "sizeX": dc["size_x"], "sizeY": dc["size_y"],
                })
            except RuntimeError as exc2:
                raise SystemExit(f"[dash] could not attach card {dc['card_id']}: {exc2}")

    print(f"\n[done] dashboard: {args.base_url}/dashboard/{dash_id}")

    if args.no_verify:
        return 0

    print("\n[verify] running every card through Metabase (this is the acceptance check)\n")
    print(f"  {'rows':>6}  {'status':<8} card")
    print(f"  {'-' * 6}  {'-' * 8} {'-' * 60}")
    empty, errors = [], []
    for c, cid in card_ids:
        try:
            _, res = mb.request("POST", f"/api/card/{cid}/query", {})
        except RuntimeError as exc:
            errors.append((c["name"], str(exc)))
            print(f"  {'ERR':>6}  {'error':<8} {c['name']}  ({exc})")
            continue
        if isinstance(res, dict) and res.get("status") not in (None, "completed"):
            errors.append((c["name"], str(res.get("error", res.get("status")))))
            print(f"  {'ERR':>6}  {'error':<8} {c['name']}")
            continue
        rows = (((res or {}).get("data") or {}).get("rows")) or []
        status = "PASS" if rows else "EMPTY"
        if not rows:
            empty.append(c["name"])
        preview = ""
        if rows:
            first = rows[0]
            preview = "  e.g. " + ", ".join(str(v) for v in first[:3])
        print(f"  {len(rows):>6}  {status:<8} {c['name']}{preview}")

    print()
    if errors:
        print(f"[verify] {len(errors)} card(s) ERRORED — fix the SQL/source before publishing:")
        for name, err in errors:
            print(f"   - {name}: {err}")
        return 1
    if empty:
        print(f"[verify] {len(empty)} card(s) returned ZERO rows (not publishable as-is):")
        for name in empty:
            print(f"   - {name}")
        print("   A zero-row card is usually a stale/empty gold mart or an empty DQ log — "
              "check `dbt run` and the LMS scenario data, do not paper over it with a literal.")
        return 2
    print(f"[verify] all {len(card_ids)} cards returned real, non-empty data")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except RuntimeError as exc:
        print(f"[error] {exc}", file=sys.stderr)
        sys.exit(1)
