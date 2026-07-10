"""The visit pipeline: measurement → transcription → extraction → estimation.

Deterministic orchestration with explicit degradation:
- Measurement failure fails the session (nothing to estimate without geometry).
- Transcription/extraction failures degrade to the default paint scope with a
  note; the painter reviews the draft anyway.

Each stage's output is written to the session directory as it completes, so a
crashed run leaves inspectable artifacts behind.
"""

from __future__ import annotations

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
        store.save(session)

        # 2. Transcription (local Whisper; optional)
        transcript = ""
        audio_path = store.audio_path(session)
        if audio_path is None:
            logger.info("%s: no audio uploaded", session.session_id)
        else:
            try:
                with self._timed(session, "transcribe"):
                    transcript = self.transcriber.transcribe(audio_path)
                session.raw_metadata["transcript_chars"] = str(len(transcript))
                store.write_artifact(session, TRANSCRIPT_FILE, transcript)
            except TranscriptionError as exc:
                logger.warning("%s: transcription failed: %s", session.session_id, exc)
                session.raw_metadata["transcription_error"] = str(exc)

        # 3. Requirements extraction (LLM; degrades to defaults)
        if not transcript.strip():
            session.requirements = default_requirements("no transcript")
        else:
            try:
                with self._timed(session, "extract"):
                    session.requirements = self.extractor.extract(transcript)
            except ExtractionError as exc:
                logger.warning("%s: extraction failed: %s", session.session_id, exc)
                session.raw_metadata["extraction_error"] = str(exc)
                session.requirements = default_requirements(str(exc))
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
