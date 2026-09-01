"""Ground-truth comparison: laser measurements vs what the engine reported.

Until this module existed, no accuracy claim in Build Pilot was falsifiable.
It pairs a laser-measured room (fixtures/ground_truth/<visit_id>.json, see
docs/GROUND_TRUTH_PROTOCOL.md) with the verbatim scan the phone uploaded
(fixtures/real_scans/<visit_id>.json) and reports signed error per dimension.

Pure functions, no pytest: the report tool and the test suite share them.
Metric throughout (Decision 9).
"""

from __future__ import annotations

import json
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Dict, List, Optional

FIXTURES = Path(__file__).parent / "fixtures"
TRUTH_DIR = FIXTURES / "ground_truth"
SCAN_DIR = FIXTURES / "real_scans"


@dataclass(frozen=True)
class Error:
    """One measured dimension: what the room is, what the engine said."""

    name: str
    truth: float
    measured: float
    unit: str = "m2"

    @property
    def absolute(self) -> float:
        return self.measured - self.truth

    @property
    def relative(self) -> Optional[float]:
        """Signed fractional error. None when truth is zero (undefined)."""
        return None if self.truth == 0 else self.absolute / self.truth

    def __str__(self) -> str:
        rel = "n/a" if self.relative is None else f"{self.relative:+.1%}"
        return (
            f"{self.name}: truth {self.truth:.2f}{self.unit}, "
            f"measured {self.measured:.2f}{self.unit} ({rel})"
        )


def load_records() -> List[Dict[str, Any]]:
    """Every ground-truth record that has a matching scan. EXAMPLE- is skipped."""
    if not TRUTH_DIR.exists():
        return []
    records = []
    for path in sorted(TRUTH_DIR.glob("*.json")):
        if path.name.startswith("EXAMPLE"):
            continue
        record = json.loads(path.read_text())
        # A scaffold from tools/pull_scan.py has no laser data yet; it must
        # not enter the corpus until the walls are filled in on site.
        if not record.get("laser", {}).get("walls_m"):
            continue
        scan = SCAN_DIR / f"{record['visit_id']}.json"
        if not scan.exists():
            continue
        record["_scan_path"] = scan
        records.append(record)
    return records


def load_scan(record: Dict[str, Any]) -> Dict[str, Any]:
    """The CapturedRoom JSON for a record (unwrapping a session envelope)."""
    raw = json.loads(Path(record["_scan_path"]).read_text())
    return raw.get("room_scan", raw)


# --- truth derived from the laser -------------------------------------------


def truth_perimeter_m(laser: Dict[str, Any]) -> float:
    return sum(float(w["length_m"]) for w in laser.get("walls_m", []))


def truth_ceiling_height_m(laser: Dict[str, Any]) -> float:
    """Mean of the corner readings. Two readings that disagree are the point:
    they mean the flat-ceiling assumption is wrong in this room."""
    heights = [float(h) for h in laser.get("ceiling_height_m", [])]
    return sum(heights) / len(heights) if heights else 0.0


def ceiling_is_level(laser: Dict[str, Any], tolerance_m: float = 0.02) -> bool:
    heights = [float(h) for h in laser.get("ceiling_height_m", [])]
    if len(heights) <= 1:
        return True
    # 1e-9 slack: a 2.46/2.44 pair differs by 0.020000000000000018 in
    # binary floating point and must not read as uneven.
    return (max(heights) - min(heights)) <= tolerance_m + 1e-9


def truth_gross_wall_area_m2(laser: Dict[str, Any]) -> float:
    return truth_perimeter_m(laser) * truth_ceiling_height_m(laser)


def truth_opening_area_m2(laser: Dict[str, Any]) -> float:
    return sum(
        float(o["width_m"]) * float(o["height_m"]) for o in laser.get("openings", [])
    )


def truth_built_in_area_m2(laser: Dict[str, Any]) -> float:
    return sum(
        float(b["width_m"]) * float(b["height_m"]) for b in laser.get("built_ins", [])
    )


def truth_net_wall_area_m2(laser: Dict[str, Any]) -> float:
    """Gross minus openings and minus wall hidden behind built-ins — the same
    definition the engine uses for net_wall_area_m2, so they are comparable."""
    return (
        truth_gross_wall_area_m2(laser)
        - truth_opening_area_m2(laser)
        - truth_built_in_area_m2(laser)
    )


# --- comparison --------------------------------------------------------------


def compare(record: Dict[str, Any], measurement: Any) -> List[Error]:
    """Signed errors for every dimension the laser record can adjudicate."""
    laser = record["laser"]
    errors = [
        Error("gross wall area", truth_gross_wall_area_m2(laser),
              measurement.gross_wall_area_m2),
        Error("net wall area", truth_net_wall_area_m2(laser),
              measurement.net_wall_area_m2),
    ]
    if measurement.perimeter_m is not None:
        errors.append(
            Error("perimeter", truth_perimeter_m(laser), measurement.perimeter_m, "m")
        )
    if measurement.ceiling_height_m is not None:
        errors.append(
            Error("ceiling height", truth_ceiling_height_m(laser),
                  measurement.ceiling_height_m, "m")
        )
    # Ceiling area is only adjudicable when the room is a simple rectangle:
    # four laser walls in two matching pairs. Anything else needs a floor
    # polygon we do not have from a laser, so we stay silent rather than guess.
    walls = [float(w["length_m"]) for w in laser.get("walls_m", [])]
    if len(walls) == 4:
        a, b, c, d = sorted(walls)
        if abs(a - b) < 0.05 and abs(c - d) < 0.05:
            errors.append(
                Error("ceiling area", a * c, measurement.ceiling_area_m2)
            )
    return errors


def completeness_status(measurement: Any) -> str:
    return measurement.completeness.status if measurement.completeness else "unknown"


def worst_relative_error(errors: List[Error]) -> float:
    """Largest absolute relative error across dimensions that define one."""
    rels = [abs(e.relative) for e in errors if e.relative is not None]
    return max(rels) if rels else 0.0
