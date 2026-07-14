"""Apply manual plan edits — deterministic, never AI.

Manual Measurement Editing lets the painter correct what the scan got wrong
(wall dimensions, openings, ceiling area, scope, coats). This module applies
those structured edits to copies of the measurements, requirements and company
profile, re-deriving wall areas from first principles. The caller then re-runs
the existing deterministic estimator on the result — no estimator formula
changes, no new pricing logic here.
"""

from __future__ import annotations

from buildpilot.models.session import (
    CompanyProfile,
    PlanEdit,
    RequirementExtraction,
    RoomMeasurement,
)

# Notes the scan added when it was incomplete; a manual verification clears them
# because the human has now confirmed the geometry on site.
_INCOMPLETE_SCAN_MARKERS = ("uncaptured walls", "bounding box")
_VERIFIED_NOTE = "Measurements manually verified on site."


def apply_plan_edit(
    measurements: RoomMeasurement,
    requirements: RequirementExtraction,
    profile: CompanyProfile,
    edit: PlanEdit,
) -> tuple[RoomMeasurement, RequirementExtraction, CompanyProfile]:
    """Returns edited copies of (measurements, requirements, profile). Inputs
    are never mutated."""
    m = measurements.model_copy(deep=True)
    r = requirements.model_copy(deep=True)
    p = profile.model_copy(deep=True)

    # --- per-wall dimensions; re-derive gross/net deterministically ----------
    if edit.walls is not None:
        by_id = {w.wall_id: w for w in m.walls}
        for we in edit.walls:
            w = by_id.get(we.wall_id)
            if w is None:
                continue
            if we.width_m is not None:
                w.width_m = max(we.width_m, 0.0)
            if we.height_m is not None:
                w.height_m = max(we.height_m, 0.0)
            if we.opening_area_m2 is not None:
                w.opening_area_m2 = max(we.opening_area_m2, 0.0)
            w.gross_area_m2 = round(w.width_m * w.height_m, 2)
            w.net_area_m2 = round(max(w.gross_area_m2 - w.opening_area_m2, 0.0), 2)
        m.gross_wall_area_m2 = round(sum(w.gross_area_m2 for w in m.walls), 2)
        m.net_wall_area_m2 = round(sum(w.net_area_m2 for w in m.walls), 2)

    # --- room-level area overrides -------------------------------------------
    if edit.ceiling_area_m2 is not None:
        m.ceiling_area_m2 = round(max(edit.ceiling_area_m2, 0.0), 2)
    if edit.door_area_m2 is not None:
        m.door_area_m2 = round(max(edit.door_area_m2, 0.0), 2)
    if edit.window_area_m2 is not None:
        m.window_area_m2 = round(max(edit.window_area_m2, 0.0), 2)
    m.paintable_surface_area_m2 = round(m.net_wall_area_m2 + m.ceiling_area_m2, 2)

    # --- scope / requirements -------------------------------------------------
    if edit.paint_scope is not None:
        r.paint_scope = edit.paint_scope
    if edit.painted_wall_ids is not None:
        known = {w.wall_id for w in m.walls}
        r.painted_wall_ids = [wid for wid in edit.painted_wall_ids if wid in known]
    if edit.scope_of_work is not None:
        r.scope_of_work = edit.scope_of_work
    if edit.exclusions is not None:
        r.exclusions = edit.exclusions
    if edit.preparation_required is not None:
        r.preparation_required = edit.preparation_required
    if edit.special_notes is not None:
        r.special_notes = edit.special_notes

    # --- coats (the only company-profile field the painter edits) ------------
    if edit.coats is not None:
        p.coats = max(int(edit.coats), 1)

    # --- manual verification clears the incomplete-scan warnings -------------
    if edit.measurements_verified:
        m.confidence_score = 1.0
        m.notes = [
            n for n in m.notes
            if not any(marker in n for marker in _INCOMPLETE_SCAN_MARKERS)
        ]
        if _VERIFIED_NOTE not in m.notes:
            m.notes.append(_VERIFIED_NOTE)

    return m, r, p
