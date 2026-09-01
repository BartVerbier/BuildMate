"""Versioned session contract for Build Pilot.

Unit policy (permanent architectural decision, see docs/DECISIONS.md):
- lengths in metres (m), areas in square metres (m2)
- paint volumes in litres, coverage in m2 per litre
- labour in hours, money in euros (EUR) for V1
- RoomPlan output is metres and is never converted internally;
  imperial conversion happens only at the display layer.
"""

from __future__ import annotations

from datetime import datetime
from enum import Enum
from typing import Any, Dict, List, Optional

from pydantic import BaseModel, Field

SESSION_SCHEMA_VERSION = "1.0"

# Every project belongs to exactly one contractor. V1 is single-tenant, so a
# well-known id backfills existing/local sessions; the multi-tenant seam
# (identity.ContractorResolver) routes real contractors to their own id
# without any change to the data model. See docs/DECISIONS.md.
DEFAULT_CONTRACTOR_ID = "default"


class SessionStatus(str, Enum):
    DRAFT = "draft"
    IN_PROGRESS = "in_progress"
    COMPLETED = "completed"
    FAILED = "failed"


class AudioCapture(BaseModel):
    """Reference to the visit audio recording stored in the session directory."""

    file_name: str
    mime_type: str = "audio/mp4"  # .m4a container
    duration_seconds: Optional[float] = Field(default=None, ge=0)
    size_bytes: Optional[int] = Field(default=None, ge=0)


class RoomScanCapture(BaseModel):
    """Reference to the RoomPlan scan stored in the session directory.

    The file is Apple's CapturedRoom encoded with JSONEncoder, verbatim.
    The phone never transforms it; the backend parses only what it needs.
    """

    file_name: str
    format: str = "captured-room-json"
    size_bytes: Optional[int] = Field(default=None, ge=0)


class WallDetail(BaseModel):
    """One reconstructed wall, individually measurable.

    `wall_id` is a session-stable short id ("w1", "w2", ...) assigned by
    wall order in the CapturedRoom JSON — the shared vocabulary between the
    gaze resolver, the requirements extractor, and the estimator. Every wall
    in the scan keeps its positional id, including excluded duplicates, so
    ids always align with the CapturedRoom wall order end-to-end.
    """

    wall_id: str
    width_m: float = Field(ge=0)
    height_m: float = Field(ge=0)
    gross_area_m2: float = Field(ge=0)
    opening_area_m2: float = Field(default=0, ge=0)  # doors/windows on this wall
    net_area_m2: float = Field(ge=0)
    # Openings assigned to this wall, by OpeningDetail.opening_id.
    opening_ids: List[str] = Field(default_factory=list)
    # Set when this surface duplicates another wall (colinear, overlapping):
    # the wall it duplicates. Duplicates are excluded from room totals but
    # keep their positional id so wall ids never shift (Decision 34).
    duplicate_of: Optional[str] = None


class OpeningDetail(BaseModel):
    """One door/window/opening, assigned to its parent wall.

    `opening_id` is positional per kind ("d1", "win1", "op1"). Assignment
    prefers RoomPlan's own `parentIdentifier`; a nearest-wall fallback covers
    scans without it. An opening that matches no wall keeps parent_wall_id
    None and is NOT subtracted from any wall (Decision 34).
    """

    opening_id: str
    kind: str  # "door" | "window" | "opening"
    parent_wall_id: Optional[str] = None
    parent_source: str = "none"  # "parent_reference" | "nearest_wall" | "none"
    width_m: float = Field(ge=0)
    height_m: float = Field(ge=0)
    area_m2: float = Field(ge=0)


class OpenWallEdge(BaseModel):
    """One open end of the wall loop — where the scan failed to close.

    Gives the app a concrete rescan target: which wall, which end, and where
    on the ground plane, instead of a bare "incomplete" flag.
    """

    wall_id: str
    end: str  # "start" | "end" along the wall's local x axis
    position_m: List[float]  # [x, z] world ground-plane coordinates, metres
    nearest_wall_id: Optional[str] = None
    gap_m: Optional[float] = Field(default=None, ge=0)
    description: str = ""


class MeasurementCompleteness(BaseModel):
    """Whether the scan geometrically accounts for the whole room.

    An incomplete scan is flagged, never silently completed — no area is
    ever fabricated (Decision 34). `open_edges` locates the gaps so the app
    can point the user straight at what to rescan.
    """

    status: str = "complete"  # "complete" | "incomplete"
    flags: List[str] = Field(default_factory=list)
    details: List[str] = Field(default_factory=list)
    # Populated when the wall loop is open: the specific open wall ends.
    open_edges: List[OpenWallEdge] = Field(default_factory=list)
    # Human override, reserved for the correction screen: "I checked the room;
    # these measurements stand". The measurement engine NEVER sets this true.
    human_confirmed: bool = False


class RoomMeasurement(BaseModel):
    """Deterministic measurement output derived from a room scan. Areas in m2."""

    gross_wall_area_m2: float = Field(ge=0)
    net_wall_area_m2: float = Field(ge=0)
    ceiling_area_m2: float = Field(ge=0)
    floor_area_m2: float = Field(ge=0)
    door_area_m2: float = Field(ge=0)
    window_area_m2: float = Field(ge=0)
    paintable_surface_area_m2: float = Field(ge=0)
    confidence_score: float = Field(ge=0, le=1)
    # Painter logic (Sprint 6): what gets moved vs protected in place.
    # Defaults keep sessions saved by earlier versions loading cleanly.
    fixed_objects: int = Field(default=0, ge=0)
    movable_objects: int = Field(default=0, ge=0)
    # Per-wall breakdown (pre-Railway sprint): lets the estimator price only
    # the walls actually being painted. Empty for sessions from older scans.
    walls: List[WallDetail] = Field(default_factory=list)
    # Per-opening breakdown with parent-wall assignment (Decision 34).
    # Empty for sessions stored by earlier versions.
    openings: List[OpeningDetail] = Field(default_factory=list)
    notes: List[str] = Field(default_factory=list)
    # Room shape facts (Decision 34). Optional so older sessions load clean.
    perimeter_m: Optional[float] = Field(default=None, ge=0)
    ceiling_height_m: Optional[float] = Field(default=None, ge=0)
    # RoomPlan cannot see the ceiling; a flat ceiling equal to the floor
    # polygon is assumed and said so explicitly, not buried in a note.
    flat_ceiling_assumed: bool = True
    # Completeness verdict: complete, or incomplete with located gaps.
    # None only on sessions stored by engine versions before Decision 34.
    completeness: Optional[MeasurementCompleteness] = None
    # Structured capture-quality signals for the confidence engine. Typed here
    # (rather than string-matched from `notes`) so scoring reads real data.
    # Optional/None means "not assessable from this scan" — the engine abstains
    # on that signal rather than penalising an older session.
    wall_perimeter_ratio: Optional[float] = Field(default=None, ge=0)
    floor_captured: Optional[bool] = None


class ConfidenceSignal(BaseModel):
    """One contributor to the overall confidence score.

    Future capture-quality signals (lighting, device motion, furniture
    occlusion, manual-edit count, ...) register as additional providers that
    emit this same shape. The engine blends whatever signals are present and
    every consumer renders them generically, so adding a signal needs no engine
    or UI redesign.
    """

    key: str
    label: str
    score: float = Field(ge=0, le=1)   # normalised quality, 1.0 = best
    weight: float = Field(ge=0)        # relative importance in the blend
    detail: str                        # plain-language explanation
    tip: Optional[str] = None          # how to improve it, when this signal is low


class ConfidenceReport(BaseModel):
    """Deterministic, explainable measurement-trust score (0-100). Never AI.

    `band` and `tips` are the display contract: consumers read the band instead
    of hard-coding a threshold, and render `tips` verbatim to guide a re-scan.
    """

    score: int = Field(ge=0, le=100)
    band: str                          # "high" | "medium" | "low"
    headline: str
    signals: List[ConfidenceSignal] = Field(default_factory=list)
    tips: List[str] = Field(default_factory=list)
    engine_version: str = "1.0"


class PaintScope(BaseModel):
    """Which surfaces the customer wants painted.

    Filled by the requirements extractor from the conversation; consumed by
    the deterministic estimator. This typed structure exists so the estimator
    never has to interpret free text.
    """

    walls: bool = True
    ceiling: bool = True


class RequirementExtraction(BaseModel):
    """Structured requirements extracted from the visit conversation."""

    scope_of_work: List[str] = Field(default_factory=list)
    exclusions: List[str] = Field(default_factory=list)
    preparation_required: List[str] = Field(default_factory=list)
    special_notes: List[str] = Field(default_factory=list)
    paint_scope: PaintScope = Field(default_factory=PaintScope)
    # Which walls are being painted, by WallDetail.wall_id. Empty means the
    # whole room's walls (the historical behavior). Filled only when the
    # conversation clearly limits painting to specific walls, grounded by
    # where the camera was pointing (the gaze resolver's annotations).
    painted_wall_ids: List[str] = Field(default_factory=list)
    # The customer's own words for a wall the extractor could NOT map to a
    # wall id (e.g. "the wall with the TV" in a post-scan revision, where
    # no gaze annotations exist). None when nothing was left unresolved.
    # LOAD-BEARING: when this is set and painted_wall_ids is empty, the
    # quote covers ALL walls despite the customer asking for specific ones
    # — every surface showing the quote must say so until the painter picks
    # the wall(s) (the money-bug of 2026-08-16: a "paint only the TV wall"
    # revision silently priced the whole room).
    unresolved_wall_reference: Optional[str] = None
    transcript_available: bool = True



class WallEdit(BaseModel):
    """One wall's manual correction from the Edit Plan screen."""

    wall_id: str
    width_m: Optional[float] = Field(default=None, gt=0)
    height_m: Optional[float] = Field(default=None, gt=0)
    opening_area_m2: Optional[float] = Field(default=None, ge=0)


class PlanEdit(BaseModel):
    """Manual plan corrections: POST /sessions/{id}/reestimate.

    The deterministic counterpart of a spoken revision — no AI anywhere.
    Only populated fields are applied. `measurements_verified` maps to
    completeness.human_confirmed: the painter's on-site confirmation that
    clears the completeness gate (Decision 34)."""

    walls: Optional[List[WallEdit]] = None
    ceiling_area_m2: Optional[float] = Field(default=None, ge=0)
    door_area_m2: Optional[float] = Field(default=None, ge=0)
    window_area_m2: Optional[float] = Field(default=None, ge=0)
    paint_scope: Optional[PaintScope] = None
    painted_wall_ids: Optional[List[str]] = None
    coats: Optional[int] = Field(default=None, ge=1, le=5)
    scope_of_work: Optional[List[str]] = None
    exclusions: Optional[List[str]] = None
    preparation_required: Optional[List[str]] = None
    special_notes: Optional[List[str]] = None
    measurements_verified: Optional[bool] = None


class CompanyProfile(BaseModel):
    """Pricing assumptions supplied to the estimator. Hard-coded defaults in V1."""

    profile_id: str = "default"
    labour_rate_eur_per_hour: float = Field(ge=0)
    paint_cost_eur_per_litre: float = Field(ge=0)
    primer_cost_eur_per_litre: float = Field(ge=0)
    paint_coverage_m2_per_litre: float = Field(gt=0)
    primer_coverage_m2_per_litre: float = Field(gt=0)
    labour_m2_per_hour: float = Field(gt=0)
    coats: int = Field(ge=1)
    waste_factor: float = Field(ge=0)
    prep_factor: float = Field(ge=0)
    profit_margin: float = Field(ge=0)
    travel_cost_eur: float = Field(ge=0)
    vat_rate: float = Field(ge=0)
    currency: str = "EUR"


class EstimateDraft(BaseModel):
    """Advisory draft estimate. The painter always has final approval."""

    paint_quantity_litres: float = Field(ge=0)
    primer_quantity_litres: float = Field(ge=0)
    labour_hours: float = Field(ge=0)
    material_cost_eur: float = Field(ge=0)
    labour_cost_eur: float = Field(ge=0)
    suggested_quotation_eur: float = Field(ge=0)
    currency: str = "EUR"
    assumptions: List[str] = Field(default_factory=list)
    # Completeness gate (Decision 34, second half): False when the scan did
    # not capture the whole room and no human has confirmed the measurements.
    # The numbers above are still computed — the painter needs the scale of
    # the job to decide whether to rescan — but no surface may present them
    # as a quotation while quotable is False.
    quotable: bool = True
    not_quotable_reason: Optional[str] = None


class Session(BaseModel):
    """The session record: one visit, one room.

    Capture artifacts (room scan, audio) are referenced by file name and live
    beside session.json in the session directory. Pipeline stages fill in the
    derived fields (measurements, requirements, estimate) as they run.
    """

    session_id: str
    schema_version: str = SESSION_SCHEMA_VERSION
    # The contractor who owns this project. Backfilled to DEFAULT_CONTRACTOR_ID
    # for sessions saved before multi-tenant support so they load unchanged.
    contractor_id: str = DEFAULT_CONTRACTOR_ID
    status: SessionStatus = SessionStatus.DRAFT
    created_at: datetime
    updated_at: datetime
    capture_device: str = "iphone"
    room_scan: Optional[RoomScanCapture] = None
    audio: Optional[AudioCapture] = None
    measurements: Optional[RoomMeasurement] = None
    requirements: Optional[RequirementExtraction] = None
    company_profile: Optional[CompanyProfile] = None
    estimate: Optional[EstimateDraft] = None
    confidence: Optional[ConfidenceReport] = None
    raw_metadata: Dict[str, Any] = Field(default_factory=dict)
