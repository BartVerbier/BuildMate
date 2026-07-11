"""Local HTTP API for the iPhone client.

Endpoints:
    GET  /health           — server + stage availability
    POST /sessions         — multipart upload (room_scan JSON, audio m4a) →
                             runs the full pipeline synchronously, returns the
                             completed Session including the draft estimate
    GET  /sessions/{id}    — re-fetch a session (reconnect after a dropped call)

Run:
    cd backend && ../.venv/bin/python -m uvicorn buildpilot.server:app --host 0.0.0.0 --port 8787

Synchronous processing is a deliberate V1 choice: one painter, one phone, one
Mac. The session directory persists every artifact, so a dropped connection
loses nothing — the phone re-fetches via GET /sessions/{id}.
"""

from __future__ import annotations

import json
import os
from pathlib import Path
from typing import Optional

from fastapi import FastAPI, File, Form, HTTPException, UploadFile
from fastapi.responses import HTMLResponse, PlainTextResponse, Response

from buildpilot.config import DEFAULT_COMPANY_PROFILE
from buildpilot.pipeline import VisitPipeline
from buildpilot.pipelines.estimator import DeterministicEstimator
from buildpilot.pipelines.extraction import ClaudeRequirementsExtractor
from buildpilot.pipelines.measurement import RoomPlanMeasurementEngine
from buildpilot.pipelines.transcription import MlxWhisperTranscriber
from buildpilot.pipelines.visualization import GeminiVisualizer, VisualizationError
from buildpilot.session_store import SessionStore

MAX_ROOM_SCAN_BYTES = 50 * 1024 * 1024
MAX_AUDIO_BYTES = 500 * 1024 * 1024
MAX_PHOTO_BYTES = 30 * 1024 * 1024


def _estimate_deltas(old, new) -> list:
    """Deterministic, human-readable differences between two estimates."""
    def eur(v):
        return f"€{abs(v):,.2f}"

    deltas = []
    if abs(new.labour_cost_eur - old.labour_cost_eur) >= 0.01:
        sign = "+" if new.labour_cost_eur > old.labour_cost_eur else "−"
        deltas.append(f"Labour {sign}{eur(new.labour_cost_eur - old.labour_cost_eur)}")
    if abs(new.material_cost_eur - old.material_cost_eur) >= 0.01:
        sign = "+" if new.material_cost_eur > old.material_cost_eur else "−"
        deltas.append(f"Materials {sign}{eur(new.material_cost_eur - old.material_cost_eur)}")
    if abs(new.paint_quantity_litres - old.paint_quantity_litres) >= 0.01:
        sign = "+" if new.paint_quantity_litres > old.paint_quantity_litres else "−"
        deltas.append(f"Paint {sign}{abs(new.paint_quantity_litres - old.paint_quantity_litres):g} L")
    if abs(new.suggested_quotation_eur - old.suggested_quotation_eur) >= 0.01:
        sign = "+" if new.suggested_quotation_eur > old.suggested_quotation_eur else "−"
        deltas.append(f"Total {sign}{eur(new.suggested_quotation_eur - old.suggested_quotation_eur)}")
    return deltas


def default_pipeline() -> VisitPipeline:
    return VisitPipeline(
        measurement_engine=RoomPlanMeasurementEngine(),
        transcriber=MlxWhisperTranscriber(),
        extractor=ClaudeRequirementsExtractor(),
        estimator=DeterministicEstimator(),
        company_profile=DEFAULT_COMPANY_PROFILE,
    )


def default_store() -> SessionStore:
    root = os.environ.get("BUILDPILOT_SESSIONS_DIR")
    if root:
        return SessionStore(Path(root))
    return SessionStore(Path(__file__).resolve().parents[1] / "sessions")


def create_app(
    pipeline: Optional[VisitPipeline] = None,
    store: Optional[SessionStore] = None,
    visualizer=None,
) -> FastAPI:
    app = FastAPI(title="Build Pilot backend", version="0.1.0")
    app.state.pipeline = pipeline or default_pipeline()
    app.state.store = store or default_store()
    app.state.visualizer = visualizer or GeminiVisualizer()

    @app.get("/health")
    def health() -> dict:
        return {
            "status": "ok",
            "transcriber_available": MlxWhisperTranscriber.is_available(),
            "extractor_credentials_hint": ClaudeRequirementsExtractor.is_available(),
        }

    @app.post("/sessions")
    async def create_session(
        room_scan: UploadFile = File(...),
        audio: Optional[UploadFile] = File(None),
    ) -> dict:
        room_bytes = await room_scan.read()
        if len(room_bytes) > MAX_ROOM_SCAN_BYTES:
            raise HTTPException(413, "Room scan too large")
        try:
            json.loads(room_bytes)
        except (ValueError, UnicodeDecodeError):
            raise HTTPException(400, "room_scan must be valid JSON (CapturedRoom export)")

        audio_bytes = None
        if audio is not None:
            audio_bytes = await audio.read()
            if len(audio_bytes) > MAX_AUDIO_BYTES:
                raise HTTPException(413, "Audio too large")

        session = app.state.store.create_session(room_bytes, audio_bytes)
        session = app.state.pipeline.run(app.state.store, session)
        return session.model_dump(mode="json")

    @app.get("/sessions")
    def list_sessions() -> list:
        return [s.model_dump(mode="json") for s in app.state.store.list_sessions()]

    @app.get("/sessions/{session_id}")
    def get_session(session_id: str) -> dict:
        return _load_or_404(session_id).model_dump(mode="json")

    @app.get("/sessions/{session_id}/room")
    def get_room_scan(session_id: str) -> dict:
        session = _load_or_404(session_id)
        try:
            return app.state.store.load_room_scan(session)
        except FileNotFoundError:
            raise HTTPException(404, "Session has no room scan")

    @app.post("/sessions/{session_id}/photos")
    async def add_photo(
        session_id: str,
        photo: UploadFile = File(...),
        kind: str = Form("before"),
    ) -> dict:
        """Archives a visit photo (before/progress/after) into the session
        directory — part of the permanent project record."""
        session = _load_or_404(session_id)
        if kind not in ("before", "progress", "after"):
            raise HTTPException(400, "kind must be before, progress, or after")
        data = await photo.read()
        if len(data) > MAX_PHOTO_BYTES:
            raise HTTPException(413, "Photo too large")
        if not data:
            raise HTTPException(400, "Empty photo")

        photos_dir = app.state.store.session_dir(session.session_id) / "photos"
        photos_dir.mkdir(exist_ok=True)
        index = len(list(photos_dir.glob(f"{kind}-*.jpg"))) + 1
        file_name = f"{kind}-{index:02d}.jpg"
        (photos_dir / file_name).write_bytes(data)
        return {"stored": f"photos/{file_name}"}

    @app.post("/sessions/{session_id}/revise")
    async def revise(session_id: str, audio: UploadFile = File(...)) -> dict:
        """Customer revision: merge spoken changes into the existing quote.

        Pipeline composition (no new stages): transcribe the change request →
        LLM-merge into the current requirements → re-run the deterministic
        estimator → re-render the visualization. The previous state is kept
        as a numbered version; deterministic price deltas join the change list.
        """
        from buildpilot.pipelines.extraction import ExtractionError
        from buildpilot.pipelines.transcription import TranscriptionError

        session = _load_or_404(session_id)
        if session.requirements is None or session.measurements is None or session.estimate is None:
            raise HTTPException(409, "Session has no completed quote to revise")

        store: SessionStore = app.state.store
        session_dir = store.session_dir(session.session_id)

        # 1. Version the current state before touching anything.
        versions_dir = session_dir / "versions"
        versions_dir.mkdir(exist_ok=True)
        version = len(list(versions_dir.glob("v*.json"))) + 1
        (versions_dir / f"v{version:02d}.json").write_text(session.model_dump_json(indent=2))

        # 2. Transcribe the revision audio.
        audio_bytes = await audio.read()
        if not audio_bytes or len(audio_bytes) > MAX_AUDIO_BYTES:
            raise HTTPException(400, "Invalid revision audio")
        revision_audio = session_dir / f"revision-{version:02d}.m4a"
        revision_audio.write_bytes(audio_bytes)
        try:
            transcript = app.state.pipeline.transcriber.transcribe(revision_audio)
        except TranscriptionError as exc:
            raise HTTPException(422, f"Couldn't transcribe the change request: {exc}")
        if not transcript.strip():
            raise HTTPException(422, "No speech detected in the change request")
        (session_dir / f"revision-{version:02d}.txt").write_text(transcript)

        # 3. Merge changes (LLM), re-estimate (deterministic).
        try:
            updated, changes = app.state.pipeline.extractor.revise(
                session.requirements, transcript
            )
        except ExtractionError as exc:
            raise HTTPException(503, f"Revision unavailable: {exc}")

        old = session.estimate
        session.requirements = updated
        session.estimate = app.state.pipeline.estimator.estimate(
            session.measurements, updated, session.company_profile or app.state.pipeline.company_profile
        )
        changes += _estimate_deltas(old, session.estimate)
        session.raw_metadata["version"] = str(version + 1)
        from datetime import datetime, timezone
        session.updated_at = datetime.now(timezone.utc)
        store.save(session)
        store.write_artifact(session, "estimate.json", session.estimate.model_dump_json(indent=2))

        # 4. Re-render the visualization from the same reference photo.
        photos_dir = session_dir / "photos"
        before_photos = sorted(photos_dir.glob("before-*.jpg")) if photos_dir.exists() else []
        rendered = False
        if before_photos:
            try:
                image = app.state.visualizer.render(before_photos[-1].read_bytes(), updated)
                index = len(list(photos_dir.glob("visualization-*.jpg"))) + 1
                (photos_dir / f"visualization-{index:02d}.jpg").write_bytes(image)
                rendered = True
            except VisualizationError as exc:
                logger_detail = str(exc)[:120]
                session.raw_metadata["revision_render_error"] = logger_detail
                store.save(session)

        return {
            "session": session.model_dump(mode="json"),
            "changes": changes,
            "version": version + 1,
            "visualization_updated": rendered,
        }

    @app.get("/sessions/{session_id}/versions")
    def list_versions(session_id: str) -> list:
        session = _load_or_404(session_id)
        versions_dir = app.state.store.session_dir(session.session_id) / "versions"
        if not versions_dir.exists():
            return []
        return sorted(int(p.stem[1:]) for p in versions_dir.glob("v*.json"))

    @app.post("/sessions/{session_id}/versions/{version}/restore")
    def restore_version(session_id: str, version: int) -> dict:
        """Restores an earlier quote version (the current state is versioned
        first, so restore is itself reversible)."""
        from buildpilot.models.session import Session as SessionModel

        session = _load_or_404(session_id)
        store: SessionStore = app.state.store
        versions_dir = store.session_dir(session.session_id) / "versions"
        target = versions_dir / f"v{version:02d}.json"
        if not target.exists():
            raise HTTPException(404, f"No version {version} for this session")

        current_n = len(list(versions_dir.glob("v*.json"))) + 1
        (versions_dir / f"v{current_n:02d}.json").write_text(session.model_dump_json(indent=2))
        restored = SessionModel.model_validate_json(target.read_text())
        restored.raw_metadata["version"] = str(current_n + 1)
        restored.raw_metadata["restored_from"] = str(version)
        store.save(restored)
        return restored.model_dump(mode="json")

    @app.post("/sessions/{session_id}/visualize")
    def visualize(session_id: str) -> Response:
        """Renders the AI "proposed result" from the newest archived Before
        photo + the extracted requirements. Returns image/jpeg."""
        session = _load_or_404(session_id)
        if session.requirements is None:
            raise HTTPException(409, "Session has no extracted requirements yet")
        # Agreement rule: the visualization must always match the estimate.
        # Degraded requirements are defaults, not the customer's words —
        # refuse to render rather than show a result nobody asked for.
        if not session.requirements.transcript_available:
            raise HTTPException(
                409, "Requirements were not extracted from the conversation; "
                     "refusing to render a visualization from default assumptions"
            )

        photos_dir = app.state.store.session_dir(session.session_id) / "photos"
        before_photos = sorted(photos_dir.glob("before-*.jpg")) if photos_dir.exists() else []
        if not before_photos:
            raise HTTPException(409, "No Before photo archived for this session")

        try:
            image = app.state.visualizer.render(
                before_photos[-1].read_bytes(), session.requirements
            )
        except VisualizationError as exc:
            raise HTTPException(503, f"Visualization unavailable: {exc}")

        index = len(list(photos_dir.glob("visualization-*.jpg"))) + 1
        (photos_dir / f"visualization-{index:02d}.jpg").write_bytes(image)
        return Response(content=image, media_type="image/jpeg")

    @app.get("/sessions/{session_id}/transcript", response_class=PlainTextResponse)
    def get_transcript(session_id: str) -> str:
        session = _load_or_404(session_id)
        path = app.state.store.session_dir(session.session_id) / "transcript.txt"
        if not path.exists():
            raise HTTPException(404, "No transcript for this session")
        return path.read_text()

    @app.get("/", response_class=HTMLResponse)
    def console() -> str:
        return (Path(__file__).parent / "console.html").read_text()

    def _load_or_404(session_id: str):
        try:
            session = app.state.store.load(session_id)
        except ValueError:
            raise HTTPException(400, "Invalid session id")
        if session is None:
            raise HTTPException(404, "Session not found")
        return session

    return app


app = create_app()
