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
API_ROOT = "https://generativelanguage.googleapis.com/v1beta"


class VisualizationError(RuntimeError):
    """Raised when the render cannot run; callers degrade gracefully."""


def build_instruction(requirements: RequirementExtraction) -> str:
    """Deterministic edit instruction from the typed requirements."""
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
        "STRICT RULES: This must remain recognisably the exact same room. "
        "Do not move, add, or remove furniture or objects. Do not change the "
        "room layout, windows, doors, or flooring unless explicitly requested. "
        "Keep the camera angle and natural lighting identical. Photorealistic "
        "only — no artistic reinterpretation. Change nothing except the "
        "finishes listed above."
    )
    return "\n".join(lines)


class GeminiVisualizer:
    """Hosted image-edit call. Requires GEMINI_API_KEY; model overridable
    via BUILDPILOT_VISUALIZER_MODEL."""

    def __init__(self, model: str | None = None) -> None:
        self.model = model or os.environ.get(
            "BUILDPILOT_VISUALIZER_MODEL", DEFAULT_VISUALIZER_MODEL
        )

    @staticmethod
    def is_available() -> bool:
        return bool(os.environ.get("GEMINI_API_KEY"))

    def render(self, photo_jpeg: bytes, requirements: RequirementExtraction) -> bytes:
        api_key = os.environ.get("GEMINI_API_KEY")
        if not api_key:
            raise VisualizationError("no GEMINI_API_KEY configured")

        instruction = build_instruction(requirements)
        logger.info(
            "Visualization request: model=%s, photo=%d kB, instruction=%d chars",
            self.model, len(photo_jpeg) // 1024, len(instruction),
        )
        started = time.perf_counter()
        body = {
            "contents": [
                {
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
            # API key goes in a header, never in the URL — URLs leak into
            # exception messages and logs.
            response = httpx.post(
                f"{API_ROOT}/models/{self.model}:generateContent",
                headers={"x-goog-api-key": api_key},
                json=body,
                timeout=90,
            )
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
