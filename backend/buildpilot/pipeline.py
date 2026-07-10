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
        try:
            return self._run(store, session)
        except MeasurementError as exc:
            logger.exception("Measurement failed for %s", session.session_id)
            session.status = SessionStatus.FAILED
            session.raw_metadata["error"] = str(exc)
            session.updated_at = datetime.now(timezone.utc)
            store.save(session)
            return session

    def _run(self, store: SessionStore, session: Session) -> Session:
        # 1. Measurement (deterministic, required)
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
                transcript = self.transcriber.transcribe(audio_path)
                store.write_artifact(session, TRANSCRIPT_FILE, transcript)
            except TranscriptionError as exc:
                logger.warning("%s: transcription failed: %s", session.session_id, exc)

        # 3. Requirements extraction (LLM; degrades to defaults)
        if not transcript.strip():
            session.requirements = default_requirements("no transcript")
        else:
            try:
                session.requirements = self.extractor.extract(transcript)
            except ExtractionError as exc:
                logger.warning("%s: extraction failed: %s", session.session_id, exc)
                session.requirements = default_requirements(str(exc))
        store.save(session)

        # 4. Deterministic estimation (never AI)
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
