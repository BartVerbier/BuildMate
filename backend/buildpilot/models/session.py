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
    gaze resolver, the requirements extractor, and the estimator.
    """

    wall_id: str
    width_m: float = Field(ge=0)
    height_m: float = Field(ge=0)
    gross_area_m2: float = Field(ge=0)
    opening_area_m2: float = Field(default=0, ge=0)  # doors/windows on this wall
    net_area_m2: float = Field(ge=0)


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
    notes: List[str] = Field(default_factory=list)


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
    transcript_available: bool = True


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


class Session(BaseModel):
    """The session record: one visit, one room.

    Capture artifacts (room scan, audio) are referenced by file name and live
    beside session.json in the session directory. Pipeline stages fill in the
    derived fields (measurements, requirements, estimate) as they run.
    """

    session_id: str
    schema_version: str = SESSION_SCHEMA_VERSION
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
    raw_metadata: Dict[str, Any] = Field(default_factory=dict)
