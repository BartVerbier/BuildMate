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

    @app.post("/sessions/{session_id}/visualize")
    def visualize(session_id: str) -> Response:
        """Renders the AI "proposed result" from the newest archived Before
        photo + the extracted requirements. Returns image/jpeg."""
        session = _load_or_404(session_id)
        if session.requirements is None:
            raise HTTPException(409, "Session has no extracted requirements yet")

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
