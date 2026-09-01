#!/usr/bin/env python3
"""Pull a visit's raw scan off the backend into the ground-truth corpus.

The bridge between a job site and the accuracy harness
(docs/GROUND_TRUTH_PROTOCOL.md): scan a room with the app, then

    python tools/pull_scan.py list             # today's visits, newest first
    python tools/pull_scan.py pull <visit-id>  # archive scan + scaffold truth
    python tools/pull_scan.py pull --latest    # ...the newest visit, no ID needed
    python tools/pull_scan.py truth --latest   # guided laser-number entry (no JSON editing)

`pull` writes the verbatim CapturedRoom JSON to
tests/fixtures/real_scans/<visit-id>.json and scaffolds
tests/fixtures/ground_truth/<visit-id>.json with the laser fields empty,
ready to fill in. The harness ignores a record until its laser walls are
filled, so a half-done scaffold can never poison the corpus.

Credentials: BUILDPILOT_API_TOKEN / BUILDPILOT_CONTRACTOR_ID env vars win;
otherwise both are read from iphone/BuildPilot/Secrets.xcconfig — the same
values the phone uses, so the tool sees exactly the sessions the phone made.
Base URL: BUILDPILOT_BASE_URL, default the production Railway deployment.
"""

from __future__ import annotations

import json
import os
import sys
from pathlib import Path

import httpx

REPO = Path(__file__).resolve().parents[2]
BACKEND = REPO / "backend"
SCAN_DIR = BACKEND / "tests" / "fixtures" / "real_scans"
TRUTH_DIR = BACKEND / "tests" / "fixtures" / "ground_truth"
XCCONFIG = REPO / "iphone" / "BuildPilot" / "Secrets.xcconfig"

DEFAULT_BASE_URL = "https://buildmate-production-4086.up.railway.app"


def _xcconfig_values() -> dict:
    values = {}
    if XCCONFIG.exists():
        for line in XCCONFIG.read_text().splitlines():
            line = line.split("//")[0].strip()
            if "=" in line:
                key, _, value = line.partition("=")
                values[key.strip()] = value.strip()
    return values


def _client() -> httpx.Client:
    secrets = _xcconfig_values()
    token = os.environ.get("BUILDPILOT_API_TOKEN") or secrets.get("BUILDMATE_API_TOKEN")
    contractor = os.environ.get("BUILDPILOT_CONTRACTOR_ID") or secrets.get(
        "BUILDMATE_CONTRACTOR_ID"
    )
    headers = {}
    if token:
        headers["Authorization"] = f"Bearer {token}"
    if contractor:
        headers["X-Contractor-Id"] = contractor
    base = os.environ.get("BUILDPILOT_BASE_URL", DEFAULT_BASE_URL)
    return httpx.Client(base_url=base, headers=headers, timeout=30.0)


def cmd_list() -> int:
    with _client() as client:
        response = client.get("/sessions")
        response.raise_for_status()
        sessions = response.json()
    if not sessions:
        print("No sessions on the backend for this contractor.")
        return 0
    for s in sessions:
        session_id = s.get("session_id", "?")
        status = s.get("status", "?")
        created = (s.get("created_at") or "")[:16].replace("T", " ")
        archived = "  [in corpus]" if (SCAN_DIR / f"{session_id}.json").exists() else ""
        print(f"{created}  {session_id}  {status}{archived}")
    return 0


def _truth_scaffold(visit_id: str) -> dict:
    """Same shape as EXAMPLE-room.json, laser fields empty. The harness skips
    a record whose walls_m is empty, so committing a scaffold is harmless."""
    return {
        "visit_id": visit_id,
        "scan_pattern": "",
        "room_label": "",
        "notes": "",
        "laser": {
            "walls_m": [],
            "ceiling_height_m": [],
            "openings": [],
            "built_ins": [],
        },
        "conditions": {
            "flooring": "",
            "mirrors_or_glass": False,
            "dark_or_gloss_walls": False,
            "brightness": "",
            "furniture_density": "",
        },
        "painter_estimate": {
            "paintable_area_m2": None,
            "prep_hours": None,
            "protection_hours": None,
            "total_hours": None,
            "materials_eur": None,
            "quoted_price_eur": None,
            "comment": "",
        },
    }


def cmd_pull(visit_id: str) -> int:
    with _client() as client:
        response = client.get(f"/sessions/{visit_id}/room")
        if response.status_code == 404:
            print(f"error: {visit_id} not found (or has no scan)", file=sys.stderr)
            return 1
        response.raise_for_status()
        room = response.json()

    SCAN_DIR.mkdir(parents=True, exist_ok=True)
    TRUTH_DIR.mkdir(parents=True, exist_ok=True)

    scan_path = SCAN_DIR / f"{visit_id}.json"
    scan_path.write_text(json.dumps(room, indent=2))
    walls = len(room.get("walls") or [])
    print(f"archived {scan_path.relative_to(REPO)} ({walls} walls)")

    truth_path = TRUTH_DIR / f"{visit_id}.json"
    if truth_path.exists():
        print(f"kept    {truth_path.relative_to(REPO)} (already has data)")
    else:
        truth_path.write_text(json.dumps(_truth_scaffold(visit_id), indent=2))
        print(f"scaffold {truth_path.relative_to(REPO)} — fill in the laser numbers")
        print("         (docs/GROUND_TRUTH_PROTOCOL.md has the routine)")
    return 0


def _latest_visit_id() -> str | None:
    with _client() as client:
        response = client.get("/sessions")
        response.raise_for_status()
        sessions = response.json()
    return sessions[0].get("session_id") if sessions else None


def _number(raw: str) -> float | None:
    """Parse a number the way a European types it: '4,62' and '4.62' both
    work; blank (or anything unparseable) is None — a missing value is
    honest, a guessed one poisons the corpus."""
    raw = raw.strip().replace(",", ".")
    if not raw:
        return None
    try:
        return float(raw)
    except ValueError:
        return None


def _ask(prompt: str) -> str:
    try:
        return input(prompt)
    except EOFError:
        return ""


def _ask_number(prompt: str) -> float | None:
    return _number(_ask(prompt))


def cmd_truth(visit_id: str) -> int:
    """Guided entry of the on-site laser numbers (docs/GROUND_TRUTH_PROTOCOL.md).
    Blank answers skip a field; nothing is ever guessed on your behalf."""
    truth_path = TRUTH_DIR / f"{visit_id}.json"
    scan_path = SCAN_DIR / f"{visit_id}.json"
    if not scan_path.exists():
        print(f"No archived scan for {visit_id} — run pull first.", file=sys.stderr)
        return 1
    record = (
        json.loads(truth_path.read_text()) if truth_path.exists()
        else _truth_scaffold(visit_id)
    )

    print(f"\nLaser numbers for {visit_id} — blank skips, ',' or '.' decimals both fine.\n")
    pattern = _ask("Scan pattern [A natural / B deliberate / C obstructed]: ").strip().upper()
    if pattern in ("A", "B", "C"):
        record["scan_pattern"] = pattern
    label = _ask("Room label (e.g. 'Living room, 1st floor'): ").strip()
    if label:
        record["room_label"] = label

    print("\nWalls — corner to corner, one per line. Blank line when done.")
    walls = []
    while True:
        value = _ask_number(f"  wall {len(walls) + 1} length (m): ")
        if value is None:
            break
        walls.append({"label": f"wall {len(walls) + 1}", "length_m": value})
    if walls:
        record["laser"]["walls_m"] = walls

    print("\nCeiling height at two opposite corners.")
    heights = [h for h in (
        _ask_number("  corner 1 (m): "), _ask_number("  corner 2 (m): ")
    ) if h is not None]
    if heights:
        record["laser"]["ceiling_height_m"] = heights

    print("\nDoors and windows — blank type when done.")
    openings = []
    while True:
        kind = _ask("  type [d]oor / [w]indow / [o]pening: ").strip().lower()
        if not kind:
            break
        kind = {"d": "door", "w": "window", "o": "opening"}.get(kind[0], kind)
        width = _ask_number("    width (m): ")
        height = _ask_number("    height (m): ")
        if width and height:
            openings.append({"type": kind, "wall": "", "width_m": width, "height_m": height})
    if openings:
        record["laser"]["openings"] = openings

    print("\nBuilt-ins touching a wall (fitted wardrobes, kitchen units) — blank name when done.")
    built_ins = []
    while True:
        what = _ask("  what is it: ").strip()
        if not what:
            break
        width = _ask_number("    width (m): ")
        height = _ask_number("    height (m): ")
        if width and height:
            built_ins.append({"what": what, "wall": "", "width_m": width, "height_m": height})
    record["laser"]["built_ins"] = built_ins

    print("\nYour own estimate — BEFORE looking at the app's number.")
    estimate = record.setdefault("painter_estimate", {})
    for key, prompt in [
        ("paintable_area_m2", "  paintable area (m2): "),
        ("prep_hours", "  prep hours: "),
        ("protection_hours", "  protection/covering hours: "),
        ("total_hours", "  total hours: "),
        ("materials_eur", "  materials (EUR): "),
        ("quoted_price_eur", "  the price you'd quote (EUR): "),
    ]:
        value = _ask_number(prompt)
        if value is not None:
            estimate[key] = value
    comment = _ask("  anything unusual about this job: ").strip()
    if comment:
        estimate["comment"] = comment

    truth_path.write_text(json.dumps(record, indent=2))
    wall_total = sum(w["length_m"] for w in record["laser"].get("walls_m", []))
    print(f"\nSaved {truth_path.name}: {len(record['laser'].get('walls_m', []))} walls "
          f"({wall_total:.2f} m), {len(record['laser'].get('ceiling_height_m', []))} ceiling "
          f"reading(s), {len(openings)} opening(s).")
    print("Next:  ../.venv/bin/python tools/accuracy_report.py")
    return 0


def main() -> int:
    args = sys.argv[1:]
    if args[:1] == ["list"]:
        return cmd_list()
    if args == ["pull", "--latest"]:
        visit_id = _latest_visit_id()
        if not visit_id:
            print("No sessions on the backend.", file=sys.stderr)
            return 1
        print(f"latest: {visit_id}")
        return cmd_pull(visit_id)
    if args[:1] == ["pull"] and len(args) == 2:
        return cmd_pull(args[1])
    if args == ["truth", "--latest"]:
        visit_id = _latest_visit_id()
        if not visit_id:
            print("No sessions on the backend.", file=sys.stderr)
            return 1
        if not (SCAN_DIR / f"{visit_id}.json").exists():
            cmd_pull(visit_id)
        return cmd_truth(visit_id)
    if args[:1] == ["truth"] and len(args) == 2:
        return cmd_truth(args[1])
    print(__doc__.strip(), file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main())
