#!/usr/bin/env python3
"""Provision the LMS POC Metabase dashboards from the card packs in ./sql/.

Two dashboards, split by audience:

  · "LMS POC — Business Performance"  <- sql/01-portfolio.sql, 02-npl.sql, 03-payments.sql
  · "LMS POC — Data Quality"          <- sql/04-data-quality.sql

Business numbers and data-quality/quarantine numbers are read by different people for
different reasons (Randy: business read; Keystone/Atlas: pipeline health), so they no
longer share a canvas. The split is a dashboard-layout change only — every card is the
same native Trino query it was before.

For each dashboard the script creates/updates one native Trino question per card
(idempotent: matched by exact name), rebuilds the layout, removes dashcards that do not
belong to that dashboard any more, then runs every card through Metabase's query API and
reports how many rows each returned.

Python 3 stdlib only — no pip install, no jq, no curl wrapper.

Usage
-----
  export METABASE_USER='you@example.com'
  export METABASE_PASSWORD='…'
  python3 provision_metabase.py --dry-run          # parse + show the two-dashboard plan
  python3 provision_metabase.py --database-name 'Lakehouse (Trino)'   # create/update + verify
  python3 provision_metabase.py --base-url http://localhost:8085

  # per-file assignment override (repeatable); PREFIX = file stem prefix or exact file name
  python3 provision_metabase.py --dashboard-map '04-data-quality=LMS POC — Data Quality'

  # legacy single-dashboard mode (all cards on one board); kept for older runbooks
  python3 provision_metabase.py --dashboard-name 'LMS POC — Everything'

Exit codes: 0 all cards created and non-empty · 1 provisioning error ·
            2 verification found an empty card · 3 dry-run completed.

WHAT IT DOES NOT DO: it never creates the Trino *database* connection unless you
pass --create-db (default off, because the connection is an operator decision —
docs/04-metabase.md §3). It never deletes cards or dashboards; it only removes
*dashcards* (tiles) that do not belong on the dashboard it is provisioning.
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
# Dashboard topology
# --------------------------------------------------------------------------- #

BUSINESS_NAME = "LMS POC — Business Performance"
DQ_NAME = "LMS POC — Data Quality"

BUSINESS_DESCRIPTION = (
    "Portfolio health, NPL/delinquency and payments from the gold layer "
    "(Trino → lakehouse.gold.*). Business read: Randy (POC demo/exec), Atlas (data-lead). "
    "Built by Prism."
)
DQ_DESCRIPTION = (
    "Data quality and quarantine from lakehouse.quarantine_lms.quarantine_lms — what the "
    "pipeline rejected and why. Ops read: Keystone (pipeline), Atlas (data-lead), Randy "
    "(occasional). Split out of the business dashboard on request so bad-data counts are "
    "never read as a business KPI. Built by Prism."
)

# Ordered: first match wins. `files` are file-stem prefixes, so "01-portfolio"
# matches sql/01-portfolio.sql and any future 01-portfolio-*.sql.
DASHBOARD_PACKS: list[dict] = [
    {
        "name": BUSINESS_NAME,
        # "… (Gold)" is what the live dashboard id=3 was called before the split; matching
        # it by alias means the split renames that board instead of orphaning it.
        "aliases": [BUSINESS_NAME, "LMS POC — Business Performance (Gold)"],
        "description": BUSINESS_DESCRIPTION,
        "files": ["01-portfolio", "02-npl", "03-payments"],
        "default": True,
    },
    {
        "name": DQ_NAME,
        "aliases": [DQ_NAME, "LMS POC — Data Quality (Quarantine)"],
        "description": DQ_DESCRIPTION,
        "files": ["04-data-quality"],
        "default": False,
    },
]

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

    names = [c["name"] for c in cards]
    dupes = sorted({n for n in names if names.count(n) > 1})
    if dupes:
        # Card identity in Metabase is the name; a dupe silently overwrites a card.
        raise SystemExit(f"[parse] duplicate card name(s) across packs: {', '.join(dupes)}")
    return cards


def _stem(card: dict) -> str:
    return Path(card["source_file"]).stem


def _matches_prefix(value: str, prefixes) -> bool:
    for prefix in prefixes:
        p = prefix.strip()
        if not p:
            continue
        if value == p or value.startswith(p):
            return True
    return False


def resolve_pack(card: dict, overrides: list[tuple[str, str]]) -> dict:
    """Pick the dashboard spec for a card: CLI overrides first, then DASHBOARD_PACKS."""
    stem, fname = _stem(card), card["source_file"]
    for prefix, dash_name in overrides:
        if _matches_prefix(stem, [prefix]) or _matches_prefix(fname, [prefix]):
            return {"name": dash_name, "aliases": [dash_name],
                    "description": f"Cards from {fname}. Provisioned by Prism.",
                    "files": [], "default": False}
    for spec in DASHBOARD_PACKS:
        if _matches_prefix(stem, spec["files"]):
            return spec
    fallback = next((s for s in DASHBOARD_PACKS if s.get("default")), DASHBOARD_PACKS[0])
    print(f"[parse] WARNING card '{card['name']}' ({fname}) matched no pack — "
          f"falling back to '{fallback['name']}'", file=sys.stderr)
    return fallback


def group_by_dashboard(cards: list[dict], overrides: list[tuple[str, str]]) -> list[dict]:
    """Group cards into dashboard specs, preserving pack order and file order."""
    order: list[dict] = []
    buckets: dict[str, list[dict]] = {}
    for card in cards:
        spec = resolve_pack(card, overrides)
        if spec["name"] not in buckets:
            buckets[spec["name"]] = []
            order.append(spec)
        buckets[spec["name"]].append(card)
    return [{**spec, "cards": buckets[spec["name"]]} for spec in order]


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

    def dashboard_detail(self, dash_id: int) -> dict:
        _, body = self.request("GET", f"/api/dashboard/{dash_id}")
        return body or {}

    def dashboard_card_ids(self, dash_id: int) -> list:
        detail = self.dashboard_detail(dash_id)
        tiles = detail.get("dashcards") or detail.get("ordered_cards") or []
        out = []
        for dc in tiles:
            cid = dc.get("card_id")
            if cid is None and isinstance(dc.get("card"), dict):
                cid = dc["card"].get("id")
            out.append((dc.get("id"), cid))
        return out


def _norm(name: str) -> str:
    return re.sub(r"[^a-z0-9]+", " ", (name or "").lower()).strip()


def _norm_key(name: str) -> str:
    """Normalised name with a trailing '(gold)' dropped, for legacy matching."""
    key = _norm(name)
    return re.sub(r"\s*\(?gold\)?\s*$", "", key).strip()


def find_dashboard(dashboards: list[dict], spec: dict):
    wanted = {spec["name"], *spec.get("aliases", [])}
    wanted_norm = {_norm(n) for n in wanted}
    wanted_key = {_norm_key(n) for n in wanted}
    for d in dashboards:
        if d.get("name") in wanted:
            return d
    for d in dashboards:
        if _norm(d.get("name", "")) in wanted_norm:
            return d
    # Legacy rename path: "LMS POC — Business Performance (Gold)" -> "… Performance".
    for d in dashboards:
        if _norm_key(d.get("name", "")) in wanted_key:
            return d
    return None


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

def parse_dashboard_map(values: list[str]) -> list[tuple[str, str]]:
    out: list[tuple[str, str]] = []
    for value in values or []:
        for chunk in value.split(","):
            chunk = chunk.strip()
            if not chunk:
                continue
            if "=" not in chunk:
                raise SystemExit(f"--dashboard-map expects PREFIX=Dashboard Name, got '{chunk}'")
            prefix, _, name = chunk.partition("=")
            prefix, name = prefix.strip(), name.strip()
            if not prefix or not name:
                raise SystemExit(f"--dashboard-map expects PREFIX=Dashboard Name, got '{chunk}'")
            out.append((prefix, name))
    return out


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--base-url", default=os.environ.get("METABASE_URL", "https://bi.onendo.cloud"))
    ap.add_argument("--user", default=os.environ.get("METABASE_USER"))
    ap.add_argument("--password", default=os.environ.get("METABASE_PASSWORD"))
    ap.add_argument("--database-name", default="Lakehouse")
    ap.add_argument("--dashboard-name", default=None,
                    help="LEGACY: put every card on this single dashboard instead of the "
                         "pack-defined split (default: two dashboards, see DASHBOARD_PACKS)")
    ap.add_argument("--dashboard-map", action="append", default=[], metavar="PREFIX=NAME",
                    help="override the file->dashboard assignment (repeatable, comma-separated ok)")
    ap.add_argument("--description", default=None,
                    help="description override (legacy --dashboard-name mode, or all dashboards)")
    ap.add_argument("--collection-id", type=int, default=None,
                    help="target collection id (default: root collection)")
    ap.add_argument("--sql-dir", default=str(Path(__file__).resolve().parent / "sql"))
    ap.add_argument("--dry-run", action="store_true", help="parse and print the plan only")
    ap.add_argument("--create-db", action="store_true",
                    help="create the Trino connection if the named database is missing")
    ap.add_argument("--no-verify", action="store_true", help="skip the post-provision row-count check")
    ap.add_argument("--allow-empty", action="store_true",
                    help="report empty cards but still exit 0 (never use for a publish)")
    args = ap.parse_args()

    overrides = parse_dashboard_map(args.dashboard_map)
    cards = load_cards(Path(args.sql_dir))

    if args.dashboard_name:
        # Legacy single-dashboard mode: everything on one board.
        groups = [{
            "name": args.dashboard_name,
            "aliases": [args.dashboard_name],
            "description": args.description or BUSINESS_DESCRIPTION,
            "cards": cards,
        }]
    else:
        groups = group_by_dashboard(cards, overrides)
        if args.description:
            for g in groups:
                g["description"] = args.description

    for g in groups:
        g["cards"] = pack_layout(g["cards"])

    print(f"[parse] {len(cards)} cards from {args.sql_dir} -> {len(groups)} dashboard(s)")
    for g in groups:
        print(f"\n[dashboard] {g['name']}  ({len(g['cards'])} cards)")
        for c in g["cards"]:
            print(f"  · {c['name']:<55} {c['display']:<7} {c['size_x']}x{c['size_y']}  <- {c['source_file']}")
    total = sum(len(g["cards"]) for g in groups)
    if total != len(cards):
        raise SystemExit(f"[parse] card accounting mismatch: {total} placed vs {len(cards)} parsed")

    if args.dry_run:
        print("\n[dry-run] no changes written")
        return 3

    if not args.user or not args.password:
        raise SystemExit("missing credentials: set METABASE_USER and METABASE_PASSWORD "
                         "(or pass --user/--password). The admin account was created in the UI.")

    mb = Metabase(args.base_url)
    mb.login(args.user, args.password)
    print(f"\n[auth] session established against {args.base_url}")

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
    dashboards = mb.list_dashboards()

    provisioned: list[dict] = []
    for g in groups:
        print(f"\n=== {g['name']} ===")
        card_ids: list[tuple[dict, int]] = []
        for c in g["cards"]:
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
                existing_cards[c["name"]] = cid
                print(f"[card] created  {cid:>4}  {c['name']}")
            card_ids.append((c, cid))

        dash = find_dashboard(dashboards, g)
        if dash:
            dash_id = dash.get("id")
            print(f"[dash] found    {dash_id}  {g['name']} (was: {dash.get('name')!r})")
        else:
            _, dash = mb.request("POST", "/api/dashboard", {
                "name": g["name"],
                "description": g["description"],
                "collection_id": args.collection_id,
            })
            dash = dash or {}
            dash_id = dash.get("id")
            if not dash_id:
                raise SystemExit(f"[dash] Metabase returned no id for '{g['name']}' — response was: {dash!r}")
            print(f"[dash] created  {dash_id}  {g['name']}")

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
                "name": g["name"],              # also renames "… (Gold)" on the first split run
                "description": g["description"],
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

        # ---------------------------------------------------------------- #
        # Split hygiene: a tile from the other pack must not survive the
        # re-layout (the business board used to hold all 37 cards).
        # ---------------------------------------------------------------- #
        expected = {cid for _, cid in card_ids}
        tiles = mb.dashboard_card_ids(dash_id)
        strays = [(dc_id, cid) for dc_id, cid in tiles if cid not in expected]
        if strays:
            print(f"[dash] removing {len(strays)} dashcard(s) that do not belong here")
            for dc_id, cid in strays:
                removed = False
                for method, path, body in (
                    ("DELETE", f"/api/dashboard/{dash_id}/dashcards/{dc_id}", None),
                    ("DELETE", f"/api/dashboard/{dash_id}/cards", {"dashcardId": dc_id}),
                    ("DELETE", f"/api/dashboard/{dash_id}/cards", {"cardId": cid}),
                ):
                    try:
                        mb.request(method, path, body)
                        removed = True
                        break
                    except RuntimeError:
                        continue
                if not removed:
                    print(f"[dash] WARNING could not remove dashcard {dc_id} (card {cid}) — "
                          f"remove it in the Metabase UI", file=sys.stderr)
        tiles = mb.dashboard_card_ids(dash_id)
        present = {cid for _, cid in tiles}
        missing = expected - present
        extra = present - expected
        if missing or extra or len(tiles) != len(expected):
            raise SystemExit(
                f"[dash] '{g['name']}' layout mismatch after apply: "
                f"{len(tiles)} tiles vs {len(expected)} expected "
                f"({len(missing)} missing, {len(extra)} extra) — "
                f"missing={sorted(missing)} extra={sorted(extra)}"
            )
        print(f"[dash] verified {len(tiles)} tiles, exactly the {g['name']} card set")

        provisioned.append({"name": g["name"], "id": dash_id, "cards": card_ids})

    print()
    for p in provisioned:
        print(f"[done] {p['name']}: {args.base_url}/dashboard/{p['id']}")

    if args.no_verify:
        return 0

    print("\n[verify] running every card through Metabase (this is the acceptance check)")
    empty, errors = [], []
    for p in provisioned:
        print(f"\n  --- {p['name']} ({args.base_url}/dashboard/{p['id']}) ---")
        print(f"  {'rows':>6}  {'status':<8} card")
        print(f"  {'-' * 6}  {'-' * 8} {'-' * 60}")
        p_empty = 0
        for c, cid in p["cards"]:
            try:
                _, res = mb.request("POST", f"/api/card/{cid}/query", {})
            except RuntimeError as exc:
                errors.append((p["name"], c["name"], str(exc)))
                print(f"  {'ERR':>6}  {'error':<8} {c['name']}  ({exc})")
                continue
            if isinstance(res, dict) and res.get("status") not in (None, "completed"):
                errors.append((p["name"], c["name"], str(res.get("error", res.get("status")))))
                print(f"  {'ERR':>6}  {'error':<8} {c['name']}")
                continue
            rows = (((res or {}).get("data") or {}).get("rows")) or []
            status = "PASS" if rows else "EMPTY"
            if not rows:
                empty.append((p["name"], c["name"]))
                p_empty += 1
            preview = ""
            if rows:
                first = rows[0]
                preview = "  e.g. " + ", ".join(str(v) for v in first[:3])
            print(f"  {len(rows):>6}  {status:<8} {c['name']}{preview}")
        verdict = "PASS" if p_empty == 0 else f"{p_empty} EMPTY"
        print(f"  -> {p['name']}: {len(p['cards'])} cards, {verdict}")

    print()
    if errors:
        print(f"[verify] {len(errors)} card(s) ERRORED — fix the SQL/source before publishing:")
        for dash_name, name, err in errors:
            print(f"   - [{dash_name}] {name}: {err}")
        return 1
    if empty:
        print(f"[verify] {len(empty)} card(s) returned ZERO rows (not publishable as-is):")
        for dash_name, name in empty:
            print(f"   - [{dash_name}] {name}")
        print("   A zero-row card is usually a stale/empty gold mart or an empty DQ log — "
              "check `dbt run` and the LMS scenario data, do not paper over it with a literal.")
        return 0 if args.allow_empty else 2
    for p in provisioned:
        print(f"[verify] {p['name']}: all {len(p['cards'])} cards returned real, non-empty data")
    print(f"[verify] {len(provisioned)} dashboards, {sum(len(p['cards']) for p in provisioned)} cards total — all non-empty")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except RuntimeError as exc:
        print(f"[error] {exc}", file=sys.stderr)
        sys.exit(1)
