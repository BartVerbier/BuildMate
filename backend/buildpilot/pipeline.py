"""The visit pipeline: measurement → transcription → extraction → estimation.

Deterministic orchestration with explicit degradation:
- Measurement failure fails the session (nothing to estimate without geometry).
- Transcription/extraction failures degrade to the default paint scope with a
  note; the painter reviews the draft anyway.

Each stage's output is written to the session directory as it completes, so a
crashed run leaves inspectable artifacts behind.
"""

from __future__ import annotations

import json
import logging
import time
from datetime import datetime, timezone

from buildpilot.models.session import CompanyProfile, Session, SessionStatus
from buildpilot.pipelines.extraction import ExtractionError, default_requirements
from buildpilot.pipelines.interfaces import (
    Estimator,
    MeasurementEngine,
    RequirementsExtractor,
    Transcriber,
)
from buildpilot.pipelines.confidence import score_measurement
from buildpilot.pipelines.measurement import MeasurementError
from buildpilot.pipelines.transcription import TranscriptionError
from buildpilot.session_store import TRANSCRIPT_FILE, SessionStore

logger = logging.getLogger(__name__)


class VisitPipeline:
    def __init__(
        self,
        measurement_engine: MeasurementEngine,
        transcriber: Transcriber,
        extractor: RequirementsExtractor,
        estimator: Estimator,
        company_profile: CompanyProfile,
    ) -> None:
        self.measurement_engine = measurement_engine
        self.transcriber = transcriber
        self.extractor = extractor
        self.estimator = estimator
        self.company_profile = company_profile

    def run(self, store: SessionStore, session: Session) -> Session:
        started = time.perf_counter()
        try:
            result = self._run(store, session)
            logger.info(
                "%s: completed in %.1fs (%s)",
                session.session_id,
                time.perf_counter() - started,
                self._timing_summary(session),
            )
            return result
        except MeasurementError as exc:
            logger.exception("Measurement failed for %s", session.session_id)
            return self._fail(store, session, str(exc))
        except Exception as exc:  # crash protection: a broken stage must never 500
            logger.exception("Unexpected pipeline error for %s", session.session_id)
            return self._fail(store, session, f"unexpected error: {exc}")

    def _fail(self, store: SessionStore, session: Session, error: str) -> Session:
        session.status = SessionStatus.FAILED
        session.raw_metadata["error"] = error
        session.updated_at = datetime.now(timezone.utc)
        store.save(session)
        return session

    def _run(self, store: SessionStore, session: Session) -> Session:
        # NOTE on raw_metadata: the iPhone decodes it as [String: String] —
        # every value written here MUST be a string (guarded by a test).

        # 1. Measurement (deterministic, required)
        with self._timed(session, "measure"):
            captured_room = store.load_room_scan(session)
            session.measurements = self.measurement_engine.measure(captured_room)
        # Confidence report: deterministic, explainable trust score over the
        # capture-quality signals. Recomputed after any manual measurement edit
        # (the same engine, with the edit-count signal then present).
        session.confidence = score_measurement(
            session.measurements, session.raw_metadata
        )
        store.save(session)

        # 2. Transcription (local Whisper; optional). Timed segments are
        #    kept when the transcriber provides them — they feed gaze
        #    resolution; plain text alone degrades to room-level extraction.
        transcript = ""
        segments: list = []
        audio_path = store.audio_path(session)
        if audio_path is None:
            logger.info("%s: no audio uploaded", session.session_id)
        else:
            try:
                with self._timed(session, "transcribe"):
                    if hasattr(self.transcriber, "transcribe_segments"):
                        transcript, segments = self.transcriber.transcribe_segments(audio_path)
                    else:
                        transcript = self.transcriber.transcribe(audio_path)
                session.raw_metadata["transcript_chars"] = str(len(transcript))
                store.write_artifact(session, TRANSCRIPT_FILE, transcript)
                if segments:
                    store.write_artifact(
                        session, "segments.json", json.dumps(segments, indent=2)
                    )
            except TranscriptionError as exc:
                logger.warning("%s: transcription failed: %s", session.session_id, exc)
                session.raw_metadata["transcription_error"] = str(exc)

        # 2b. Gaze resolution (deterministic geometry, optional): annotate
        #     each spoken segment with the wall the camera was facing, so
        #     "this wall" becomes a wall id the extractor can reference.
        extraction_transcript = transcript
        if segments:
            poses = store.load_poses(session)
            if poses:
                try:
                    from buildpilot.pipelines.gaze import annotate_segments, annotated_transcript

                    walls_json = captured_room.get("walls") or []
                    annotations = annotate_segments(segments, poses, walls_json)
                    store.write_artifact(
                        session, "gaze.json", json.dumps(annotations, indent=2)
                    )
                    resolved = sum(1 for a in annotations if a.get("wall_id"))
                    session.raw_metadata["gaze_resolved_segments"] = (
                        f"{resolved}/{len(annotations)}"
                    )
                    if resolved:
                        extraction_transcript = annotated_transcript(annotations)
                except Exception as exc:  # gaze is an enhancement, never a blocker
                    logger.warning("%s: gaze resolution failed: %s", session.session_id, exc)
                    session.raw_metadata["gaze_error"] = str(exc)

        # 3. Requirements extraction (LLM; degrades to defaults)
        if not transcript.strip():
            session.requirements = default_requirements("no transcript")
        else:
            try:
                with self._timed(session, "extract"):
                    session.requirements = self.extractor.extract(
                        extraction_transcript,
                        room_context=self._room_context(session),
                    )
            except ExtractionError as exc:
                logger.warning("%s: extraction failed: %s", session.session_id, exc)
                session.raw_metadata["extraction_error"] = str(exc)
                session.requirements = default_requirements(str(exc))
        # Hard constraint: the model may only reference walls that exist.
        # Unknown ids are dropped; an empty result means "all walls".
        if session.requirements and session.measurements:
            known = {w.wall_id for w in session.measurements.walls}
            requested = session.requirements.painted_wall_ids
            session.requirements.painted_wall_ids = [
                wall_id for wall_id in requested if wall_id in known
            ]
            # Backstop: the customer limited painting to specific walls but
            # every id the model gave was bogus. Empty ids price the WHOLE
            # room — that must never be silent (Decision 34 spirit: flag,
            # don't paper over).
            if requested and not session.requirements.painted_wall_ids:
                session.requirements.unresolved_wall_reference = (
                    session.requirements.unresolved_wall_reference
                    or "the wall(s) described in the conversation"
                )
        store.save(session)

        # 4. Deterministic estimation (never AI)
        with self._timed(session, "estimate"):
            session.company_profile = self.company_profile
            session.estimate = self.estimator.estimate(
                session.measurements, session.requirements, self.company_profile
            )
        session.status = SessionStatus.COMPLETED
        session.updated_at = datetime.now(timezone.utc)
        store.save(session)
        store.write_artifact(
            session, "estimate.json", session.estimate.model_dump_json(indent=2)
        )
        return session

    @staticmethod
    def _room_context(session: Session) -> str:
        """The wall inventory handed to the extractor — the only ids it may
        reference in painted_wall_ids."""
        measurements = session.measurements
        if measurements is None or not measurements.walls:
            return ""
        lines = ["Walls in this room (from the 3D scan):"]
        for w in measurements.walls:
            lines.append(
                f"- {w.wall_id}: {w.width_m:.2f} m wide x {w.height_m:.2f} m high"
                f" ({w.net_area_m2:.2f} m2 paintable)"
            )
        return "\n".join(lines)

    class _timed:
        """Records a stage duration into raw_metadata as `timing_<stage>_s`."""

        def __init__(self, session: Session, stage: str) -> None:
            self.session = session
            self.stage = stage

        def __enter__(self) -> None:
            self.started = time.perf_counter()

        def __exit__(self, *exc_info) -> None:
            elapsed = time.perf_counter() - self.started
            self.session.raw_metadata[f"timing_{self.stage}_s"] = f"{elapsed:.2f}"

    @staticmethod
    def _timing_summary(session: Session) -> str:
        parts = [
            f"{key.removeprefix('timing_').removesuffix('_s')} {value}s"
            for key, value in session.raw_metadata.items()
            if key.startswith("timing_")
        ]
        return ", ".join(parts) or "no timings"
