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

from fastapi import Depends, FastAPI, File, Form, HTTPException, UploadFile
from fastapi.responses import HTMLResponse, PlainTextResponse, Response

from buildpilot.auth import auth_enabled, require_token
from buildpilot.config import DEFAULT_COMPANY_PROFILE
from buildpilot.identity import Contractor, ContractorResolver, current_contractor
from buildpilot.pipeline import VisitPipeline
from buildpilot.pipelines.estimator import DeterministicEstimator
from buildpilot.pipelines.extraction import ClaudeRequirementsExtractor
from buildpilot.pipelines.measurement import RoomPlanMeasurementEngine
from buildpilot.pipelines.transcription import MlxWhisperTranscriber, select_transcriber
from buildpilot.pipelines.visualization import GeminiVisualizer, VisualizationError
from buildpilot.session_store import POSES_FILE, SessionStore

MAX_ROOM_SCAN_BYTES = 50 * 1024 * 1024
MAX_AUDIO_BYTES = 500 * 1024 * 1024
MAX_PHOTO_BYTES = 30 * 1024 * 1024
MAX_POSES_BYTES = 10 * 1024 * 1024
PHOTO_TIMES_FILE = "photo-times.json"


def backend_version() -> dict:
    """Identifies exactly which code this backend is running, so the phone and
    a curl can confirm they match a specific commit.

    On Railway the deployed commit is injected as RAILWAY_GIT_COMMIT_SHA. Locally
    we read it from git and flag a dirty (uncommitted) tree — a dirty backend
    matches no commit and no other machine, which is itself the answer.
    """
    sha = os.environ.get("RAILWAY_GIT_COMMIT_SHA") or os.environ.get("SOURCE_COMMIT")
    if sha:
        return {"commit": sha[:12], "source": "railway"}
    try:
        import subprocess

        root = Path(__file__).resolve().parents[2]
        head = subprocess.run(
            ["git", "-C", str(root), "rev-parse", "--short=12", "HEAD"],
            capture_output=True, text=True, timeout=2,
        )
        if head.returncode == 0:
            commit = head.stdout.strip()
            dirty = subprocess.run(
                ["git", "-C", str(root), "status", "--porcelain"],
                capture_output=True, text=True, timeout=2,
            )
            if dirty.stdout.strip():
                commit += "-dirty"
            return {"commit": commit, "source": "git"}
    except Exception:
        pass
    return {"commit": "unknown", "source": "none"}


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
        transcriber=select_transcriber(),  # MLX on the Mac, faster-whisper on Railway
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
    # Global bearer-token gate. It applies to every route; the dependency
    # itself no-ops for /health and when no token is configured (local dev),
    # so protection is on-by-default for any endpoint added later.
    app = FastAPI(
        title="Build Pilot backend",
        version="0.1.0",
        dependencies=[Depends(require_token)],
    )
    app.state.pipeline = pipeline or default_pipeline()
    app.state.store = store or default_store()
    app.state.visualizer = visualizer or GeminiVisualizer()
    # The multi-tenant seam: resolves which contractor owns each request. The
    # default is single-tenant; a deployment swaps in a credential-deriving
    # resolver without touching the routes below.
    app.state.contractor_resolver = ContractorResolver()

    @app.get("/health")
    def health() -> dict:
        from buildpilot.pipelines.transcription import FasterWhisperTranscriber

        return {
            "status": "ok",
            "version": backend_version(),
            "authentication": "enabled" if auth_enabled() else "disabled",
            "transcriber_available": (
                MlxWhisperTranscriber.is_available()
                or FasterWhisperTranscriber.is_available()
            ),
            "extractor_credentials_hint": ClaudeRequirementsExtractor.is_available(),
            # Whether the "proposed result" / "after" render is available. The
            # phone reads this to explain a missing visualization instead of
            # showing a silently-empty preview.
            "visualizer_available": bool(
                getattr(app.state.visualizer, "is_available", lambda: False)()
            ),
        }

    @app.post("/sessions")
    async def create_session(
        room_scan: UploadFile = File(...),
        audio: Optional[UploadFile] = File(None),
        poses: Optional[UploadFile] = File(None),
        contractor: Contractor = Depends(current_contractor),
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

        # Camera pose log (optional, best-effort): powers gaze resolution
        # and reference-photo selection. A malformed log is dropped, never
        # a failed visit.
        poses_list = None
        if poses is not None:
            poses_bytes = await poses.read()
            if len(poses_bytes) <= MAX_POSES_BYTES:
                try:
                    parsed = json.loads(poses_bytes)
                    if isinstance(parsed, list):
                        poses_list = parsed
                except (ValueError, UnicodeDecodeError):
                    pass

        session = app.state.store.create_session(
            room_bytes, audio_bytes, contractor_id=contractor.contractor_id
        )
        if poses_list is not None:
            app.state.store.write_artifact(
                session, POSES_FILE, json.dumps(poses_list)
            )
        session = app.state.pipeline.run(app.state.store, session)
        return session.model_dump(mode="json")

    @app.get("/sessions")
    def list_sessions(
        contractor: Contractor = Depends(current_contractor),
    ) -> list:
        return [
            s.model_dump(mode="json")
            for s in app.state.store.list_sessions(contractor.contractor_id)
        ]

    @app.get("/sessions/{session_id}")
    def get_session(
        session_id: str, contractor: Contractor = Depends(current_contractor)
    ) -> dict:
        return _load_or_404(session_id, contractor.contractor_id).model_dump(mode="json")

    @app.get("/sessions/{session_id}/room")
    def get_room_scan(
        session_id: str, contractor: Contractor = Depends(current_contractor)
    ) -> dict:
        session = _load_or_404(session_id, contractor.contractor_id)
        try:
            return app.state.store.load_room_scan(session)
        except FileNotFoundError:
            raise HTTPException(404, "Session has no room scan")

    @app.post("/sessions/{session_id}/photos")
    async def add_photo(
        session_id: str,
        photo: UploadFile = File(...),
        kind: str = Form("before"),
        t: Optional[float] = Form(None),
        contractor: Contractor = Depends(current_contractor),
    ) -> dict:
        """Archives a visit photo (before/progress/after) into the session
        directory — part of the permanent project record. `t` is the frame's
        capture time on the visit clock (seconds since the audio recording
        started); it links the photo to a camera pose for reference selection."""
        session = _load_or_404(session_id, contractor.contractor_id)
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
        if t is not None:
            times_path = photos_dir / PHOTO_TIMES_FILE
            times = {}
            if times_path.exists():
                try:
                    times = json.loads(times_path.read_text())
                except ValueError:
                    times = {}
            times[file_name] = float(t)
            times_path.write_text(json.dumps(times, indent=2))
        return {"stored": f"photos/{file_name}"}

    @app.post("/sessions/{session_id}/revise")
    async def revise(
        session_id: str,
        audio: UploadFile = File(...),
        contractor: Contractor = Depends(current_contractor),
    ) -> dict:
        """Customer revision: merge spoken changes into the existing quote.

        Pipeline composition (no new stages): transcribe the change request →
        LLM-merge into the current requirements → re-run the deterministic
        estimator → re-render the visualization. The previous state is kept
        as a numbered version; deterministic price deltas join the change list.
        """
        from buildpilot.pipelines.extraction import ExtractionError
        from buildpilot.pipelines.transcription import TranscriptionError

        session = _load_or_404(session_id, contractor.contractor_id)
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
                session.requirements, transcript,
                room_context=VisitPipeline._room_context(session),
            )
        except ExtractionError as exc:
            raise HTTPException(503, f"Revision unavailable: {exc}")
        # Hard constraint (same as the pipeline): only walls that exist.
        if session.measurements:
            known = {w.wall_id for w in session.measurements.walls}
            requested = updated.painted_wall_ids
            updated.painted_wall_ids = [
                wall_id for wall_id in requested if wall_id in known
            ]
            # Backstop: specific walls were named but none matched the scan.
            if requested and not updated.painted_wall_ids:
                updated.unresolved_wall_reference = (
                    updated.unresolved_wall_reference
                    or "the wall(s) described in the change"
                )

        # An unresolved wall reference means the quote covers ALL walls
        # despite the customer asking for specific ones — the change list
        # must say so in words the painter cannot miss, and the app blocks
        # on a wall choice (Edit Plan) until painted_wall_ids is filled.
        if updated.unresolved_wall_reference and not updated.painted_wall_ids:
            changes.append(
                f"Couldn't match “{updated.unresolved_wall_reference}” "
                "to a specific wall — the quote still covers ALL walls. "
                "Choose the wall(s) in Edit Plan."
            )

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

        # 4. The old visualization no longer matches the quote. Rendering
        #    here would waste a paid image call the phone can never download —
        #    instead the response tells the phone to re-request renders via
        #    POST /visualize, the same path as after the original scan.
        photos_dir = session_dir / "photos"
        before_photos = sorted(photos_dir.glob("before-*.jpg")) if photos_dir.exists() else []

        return {
            "session": session.model_dump(mode="json"),
            "changes": changes,
            "version": version + 1,
            "render_required": bool(before_photos),
        }

    @app.get("/sessions/{session_id}/versions")
    def list_versions(
        session_id: str, contractor: Contractor = Depends(current_contractor)
    ) -> list:
        session = _load_or_404(session_id, contractor.contractor_id)
        versions_dir = app.state.store.session_dir(session.session_id) / "versions"
        if not versions_dir.exists():
            return []
        return sorted(int(p.stem[1:]) for p in versions_dir.glob("v*.json"))

    @app.post("/sessions/{session_id}/versions/{version}/restore")
    def restore_version(
        session_id: str,
        version: int,
        contractor: Contractor = Depends(current_contractor),
    ) -> dict:
        """Restores an earlier quote version (the current state is versioned
        first, so restore is itself reversible)."""
        from buildpilot.models.session import Session as SessionModel

        session = _load_or_404(session_id, contractor.contractor_id)
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
    def visualize(
        session_id: str,
        stage: str = "finished",
        contractor: Contractor = Depends(current_contractor),
    ) -> Response:
        """Renders an AI stage image from the newest archived Before photo +
        the extracted requirements. Returns image/jpeg.

        stage=finished (default): the proposed completed result.
        stage=preparation: the room professionally prepared for painting.
        """
        if stage not in ("finished", "preparation"):
            raise HTTPException(400, "stage must be 'finished' or 'preparation'")
        session = _load_or_404(session_id, contractor.contractor_id)
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

        reference = _select_reference(session, photos_dir, before_photos)
        try:
            image = app.state.visualizer.render(
                reference.read_bytes(), session.requirements, stage
            )
        except VisualizationError as exc:
            raise HTTPException(503, f"Visualization unavailable: {exc}")

        prefix = "visualization" if stage == "finished" else "preparation"
        index = len(list(photos_dir.glob(f"{prefix}-*.jpg"))) + 1
        (photos_dir / f"{prefix}-{index:02d}.jpg").write_bytes(image)
        return Response(content=image, media_type="image/jpeg")

    @app.get("/sessions/{session_id}/transcript", response_class=PlainTextResponse)
    def get_transcript(
        session_id: str, contractor: Contractor = Depends(current_contractor)
    ) -> str:
        session = _load_or_404(session_id, contractor.contractor_id)
        path = app.state.store.session_dir(session.session_id) / "transcript.txt"
        if not path.exists():
            raise HTTPException(404, "No transcript for this session")
        return path.read_text()

    @app.get("/sessions/{session_id}/debug/wall-projection")
    def debug_wall_projection(
        session_id: str,
        format: str = "html",
        contractor: Contractor = Depends(current_contractor),
    ) -> Response:
        """INTERNAL debug (Stage 0 of the per-wall visualization redesign).

        Reports where each RoomPlan wall + its openings project onto the best
        Before frame, with a conservative confidence band. Generates NO
        visualization and never touches /visualize, the estimator, or pricing.
        Disabled unless BUILDPILOT_DEBUG_PROJECTION is set — 404 otherwise, so
        it is never exposed in production by default.
        """
        if not os.environ.get("BUILDPILOT_DEBUG_PROJECTION"):
            raise HTTPException(404, "Not Found")
        from buildpilot.pipelines import wall_projection_debug as dbg
        from buildpilot.pipelines.wall_projection import project_walls, read_jpeg_size

        session = _load_or_404(session_id, contractor.contractor_id)
        store: SessionStore = app.state.store
        photos_dir = store.session_dir(session.session_id) / "photos"
        before = sorted(photos_dir.glob("before-*.jpg")) if photos_dir.exists() else []
        times_path = photos_dir / PHOTO_TIMES_FILE
        frame_times = json.loads(times_path.read_text()) if times_path.exists() else {}
        images = {p.name: p.read_bytes() for p in before}
        jpeg_sizes = {
            name: size for name, data in images.items()
            if (size := read_jpeg_size(data)) is not None
        }
        room_json = store.load_room_scan(session)
        poses = store.load_poses(session)

        results = project_walls(room_json, poses, frame_times, jpeg_sizes)
        if format == "json":
            from fastapi.responses import JSONResponse
            return JSONResponse(dbg.summary(results))
        return HTMLResponse(dbg.render_html(results, images, jpeg_sizes))

    @app.get("/", response_class=HTMLResponse)
    def console() -> str:
        return (Path(__file__).parent / "console.html").read_text()

    def _select_reference(session, photos_dir: Path, before_photos: list) -> Path:
        """The Before photo that shows the painted wall(s) most completely.

        Deterministic geometry: each archived photo's capture time links it
        to a camera pose, and the pose projects the target walls into the
        frame (pipelines/gaze.py). Highest coverage wins; ties and missing
        data (older app builds) fall back to the newest photo — the phone's
        own best-quality pick.
        """
        fallback = before_photos[-1]
        times_path = photos_dir / PHOTO_TIMES_FILE
        if not times_path.exists():
            return fallback
        try:
            from buildpilot.pipelines.gaze import score_reference_frames

            times = json.loads(times_path.read_text())
            poses = app.state.store.load_poses(session)
            walls_json = app.state.store.load_room_scan(session).get("walls") or []
            target_ids = session.requirements.painted_wall_ids if session.requirements else []
            names = {p.name for p in before_photos}
            scores = score_reference_frames(
                {n: t for n, t in times.items() if n in names},
                poses, walls_json, target_ids,
            )
        except Exception:
            return fallback
        if not scores or max(scores.values()) <= 0:
            return fallback
        best = max(scores, key=lambda n: (scores[n], n))
        import logging
        logging.getLogger(__name__).info(
            "Reference selection: %s (coverage %.2f) of %d candidates%s",
            best, scores[best], len(before_photos),
            f", target walls {target_ids}" if target_ids else "",
        )
        return photos_dir / best

    def _load_or_404(session_id: str, contractor_id: Optional[str] = None):
        # Ownership is enforced in the store: a session owned by a different
        # contractor loads as None here, so it is indistinguishable from
        # "not found" — a contractor can't even probe for another's ids.
        try:
            session = app.state.store.load(session_id, contractor_id)
        except ValueError:
            raise HTTPException(400, "Invalid session id")
        if session is None:
            raise HTTPException(404, "Session not found")
        return session

    return app


app = create_app()
