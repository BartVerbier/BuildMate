"""AI visualization adapter — renders the "proposed result" image.

Takes a real Before photo of the room plus the extracted requirements and
returns the same photo with ONLY the requested finishes changed, via a
hosted instruction-based image-editing model (Gemini 2.5 Flash Image).

This is presentation AI (Decision 23): it never influences measurements or
the estimate, and it degrades invisibly when unavailable. Accuracy over
beauty — the customer must recognize their own room.
"""

from __future__ import annotations

import base64
import logging
import os
import time

import httpx

logger = logging.getLogger(__name__)

from buildpilot.models.session import RequirementExtraction

DEFAULT_VISUALIZER_MODEL = "gemini-2.5-flash-image"
DEVELOPER_API_ROOT = "https://generativelanguage.googleapis.com/v1beta"


class VisualizationError(RuntimeError):
    """Raised when the render cannot run; callers degrade gracefully."""


# Fidelity over polish: the customer must recognise their OWN room. Earlier
# wording ("complete walls floor to ceiling", "professional architectural
# photography", "wide") invited the model to reframe and invent a different
# room. This enforces a strict in-place edit of the uploaded source photo.
_FRAMING_RULES = (
    "IN-PLACE EDIT: Treat this strictly as an in-place edit of the uploaded "
    "source photograph. The output must be the SAME photo, with only the "
    "requested wall surfaces changed. Keep the identical framing, field of "
    "view, crop, camera position, angle, and perspective as the source. Do "
    "NOT reframe, re-crop, zoom in or out, pan, widen, straighten, or extend "
    "the image, and do NOT generate any wall, area, or object that is not "
    "already visible in the source. Preserve every existing element exactly as "
    "in the source: wall geometry and edges, ceiling, floor, windows, doors, "
    "furniture, fixtures and all visible objects, together with the original "
    "lighting, shadows, reflections and colour balance. Do NOT invent a "
    "different room, a different house, a new wall or window layout, or a "
    "staged architectural-photography composition. Photorealistic only, no "
    "reinterpretation — the customer must recognise their own room."
)

_SAME_ROOM_RULES = (
    "STRICT RULES: This must remain recognisably the exact same room, from "
    "the identical camera position, angle and perspective. Do not change the "
    "room layout, walls, windows, doors, or flooring materials."
)


def build_instruction(
    requirements: RequirementExtraction, stage: str = "finished"
) -> str:
    """Deterministic edit instruction from the typed requirements.

    Stages (Sprint 6, item 3):
    - "finished": the completed result — finishes changed, furniture back.
    - "preparation": the room professionally prepared for painting —
      furniture moved and covered, floors protected, masking up, walls
      still in their ORIGINAL state (nothing painted yet).
    """
    if stage == "preparation":
        lines = [
            "Edit this photo of a room to show it professionally PREPARED for "
            "painting work, the way a master painting crew leaves it before "
            "the first coat:",
            "- Move all freestanding furniture to the centre of the room and "
            "cover it completely with clean white dust sheets.",
            "- Protect the entire floor with taped-down floor protection "
            "(drop cloths or protection board).",
            "- Cover built-in units, radiators and window sills with plastic "
            "sheeting and masking tape; mask edges, sockets and switches "
            "with painter's tape.",
            "- Remove all pictures, mirrors, curtains and wall-mounted items "
            "(including any TV) from the walls.",
            "- The walls and ceiling keep their CURRENT, unpainted state — "
            "no new paint anywhere yet.",
            _SAME_ROOM_RULES,
            _FRAMING_RULES,
        ]
        return "\n".join(lines)

    lines = [
        "Edit this photo of a room to show the finished result after "
        "professional painting work. Apply ONLY these changes:"
    ]
    for item in requirements.scope_of_work:
        lines.append(f"- {item}")
    for item in requirements.preparation_required:
        lines.append(f"- {item} (show the repaired, finished state)")
    for item in requirements.exclusions:
        lines.append(f"- Do NOT change: {item}")
    for note in requirements.special_notes:
        lines.append(f"- Note: {note}")
    if not requirements.scope_of_work:
        lines.append("- Freshly repaint the walls in the same or a neutral colour.")
    lines.append(
        _SAME_ROOM_RULES
        + " Do not move, add, or remove furniture or objects — everything is "
        "back in its place. Change nothing except the finishes listed above."
    )
    lines.append(
        "QUALITY: The work must look professionally executed — true, "
        "freshly-painted colours with crisp, masked-quality edges along trim, "
        "corners and the ceiling line, as if finished by master painters. "
        "Natural wood, stone, glass, windows, radiators and trim keep their "
        "original finish unless explicitly listed above."
    )
    lines.append(_FRAMING_RULES)
    return "\n".join(lines)


class GeminiVisualizer:
    """Hosted image-edit call — same model, two billing doors:

    - Vertex AI (preferred when GOOGLE_CLOUD_PROJECT is set): bills the
      Google Cloud project, so GCP trial credits apply. Auth via a service
      account key (GOOGLE_APPLICATION_CREDENTIALS) using google-auth.
    - Developer API (GEMINI_API_KEY): AI Studio prepay billing.

    Model overridable via BUILDPILOT_VISUALIZER_MODEL; Vertex location via
    GOOGLE_CLOUD_LOCATION (default "global").
    """

    _vertex_credentials = None  # cached; refreshed when expired

    def __init__(self, model: str | None = None) -> None:
        self.model = model or os.environ.get(
            "BUILDPILOT_VISUALIZER_MODEL", DEFAULT_VISUALIZER_MODEL
        )

    @staticmethod
    def is_available() -> bool:
        return bool(
            os.environ.get("GOOGLE_CLOUD_PROJECT") or os.environ.get("GEMINI_API_KEY")
        )

    def _endpoint_and_headers(self) -> tuple[str, dict]:
        project = os.environ.get("GOOGLE_CLOUD_PROJECT")
        if project:
            location = os.environ.get("GOOGLE_CLOUD_LOCATION", "global")
            host = (
                "aiplatform.googleapis.com"
                if location == "global"
                else f"{location}-aiplatform.googleapis.com"
            )
            url = (
                f"https://{host}/v1/projects/{project}/locations/{location}"
                f"/publishers/google/models/{self.model}:generateContent"
            )
            return url, {"Authorization": f"Bearer {self._vertex_token()}"}

        api_key = os.environ.get("GEMINI_API_KEY")
        if not api_key:
            raise VisualizationError(
                "no GOOGLE_CLOUD_PROJECT or GEMINI_API_KEY configured"
            )
        return (
            f"{DEVELOPER_API_ROOT}/models/{self.model}:generateContent",
            {"x-goog-api-key": api_key},
        )

    @classmethod
    def _vertex_token(cls) -> str:
        try:
            import google.auth
            from google.auth.transport.requests import Request
        except ImportError as exc:
            raise VisualizationError("google-auth is not installed") from exc
        try:
            if cls._vertex_credentials is None:
                cls._vertex_credentials, _ = google.auth.default(
                    scopes=["https://www.googleapis.com/auth/cloud-platform"]
                )
            if not cls._vertex_credentials.valid:
                cls._vertex_credentials.refresh(Request())
            return cls._vertex_credentials.token
        except VisualizationError:
            raise
        except Exception as exc:
            raise VisualizationError(
                f"Vertex credentials unavailable ({type(exc).__name__}): "
                "check GOOGLE_APPLICATION_CREDENTIALS points at a valid "
                "service-account key with the Vertex AI User role"
            ) from None

    def render(
        self,
        photo_jpeg: bytes,
        requirements: RequirementExtraction,
        stage: str = "finished",
    ) -> bytes:
        url, headers = self._endpoint_and_headers()

        instruction = build_instruction(requirements, stage)
        logger.info(
            "Visualization request: stage=%s, model=%s via %s, photo=%d kB, instruction=%d chars",
            stage, self.model,
            "Vertex AI" if os.environ.get("GOOGLE_CLOUD_PROJECT") else "Developer API",
            len(photo_jpeg) // 1024, len(instruction),
        )
        started = time.perf_counter()
        body = {
            "contents": [
                {
                    "role": "user",  # required by Vertex AI; accepted by the Developer API
                    "parts": [
                        {"text": instruction},
                        {
                            "inline_data": {
                                "mime_type": "image/jpeg",
                                "data": base64.b64encode(photo_jpeg).decode(),
                            }
                        },
                    ]
                }
            ]
        }
        try:
            # Credentials go in headers, never in the URL — URLs leak into
            # exception messages and logs.
            response = httpx.post(url, headers=headers, json=body, timeout=90)
            response.raise_for_status()
        except httpx.HTTPStatusError as exc:
            raise VisualizationError(
                f"image model returned HTTP {exc.response.status_code}: "
                f"{exc.response.text[:200]}"
            ) from None
        except httpx.HTTPError as exc:
            raise VisualizationError(
                f"image model request failed: {type(exc).__name__}"
            ) from None

        try:
            for candidate in response.json().get("candidates", []):
                for part in candidate.get("content", {}).get("parts", []):
                    inline = part.get("inline_data") or part.get("inlineData")
                    if inline and inline.get("data"):
                        image = base64.b64decode(inline["data"])
                        logger.info(
                            "Visualization response in %.1fs: %d kB image",
                            time.perf_counter() - started, len(image) // 1024,
                        )
                        return image
        except (ValueError, KeyError, TypeError) as exc:
            raise VisualizationError(f"unexpected image model response: {exc}") from exc
        raise VisualizationError("image model returned no image")
