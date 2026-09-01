"""Stage 0 debug artifacts — a self-contained HTML/SVG overlay + JSON summary
for the wall→pixel projection. No image-processing dependency: the Before JPEGs
are embedded as data URIs and the projected polygons are drawn as inline SVG in
the JPEG's own pixel space, so what you see is exactly where the geometry lands.

Purely diagnostic. Generates no visualization and touches no production path.
"""

from __future__ import annotations

import base64
import html
from typing import Any, Dict, List, Tuple

_BAND_COLOR = {"high": "#2ecc71", "medium": "#f39c12", "low": "#e74c3c"}


def summary(results: List[Dict[str, Any]]) -> Dict[str, Any]:
    counts: Dict[str, int] = {"high": 0, "medium": 0, "low": 0}
    for r in results:
        counts[r.get("band", "low")] = counts.get(r.get("band", "low"), 0) + 1
    return {"wall_count": len(results), "bands": counts, "walls": results}


def _poly(points: List[Any]) -> str:
    """SVG points string from [[u,v], ...], skipping corners that didn't project."""
    return " ".join(f"{p[0]},{p[1]}" for p in points if p)


def _data_uri(jpeg: bytes) -> str:
    return "data:image/jpeg;base64," + base64.b64encode(jpeg).decode()


def render_html(
    results: List[Dict[str, Any]],
    images: Dict[str, bytes],
    jpeg_sizes: Dict[str, Tuple[int, int]],
) -> str:
    counts = summary(results)["bands"]
    parts: List[str] = [
        "<!doctype html><meta charset='utf-8'>",
        "<title>Wall projection — Stage 0</title>",
        "<style>body{font:14px -apple-system,system-ui,sans-serif;margin:20px;"
        "background:#111;color:#eee}h2{margin:24px 0 6px}"
        "table{border-collapse:collapse;margin:8px 0}td,th{border:1px solid #333;"
        "padding:4px 8px;text-align:left}svg{background:#000;max-width:100%;height:auto;"
        "border:1px solid #333}.pill{padding:1px 8px;border-radius:8px;color:#000;"
        "font-weight:600}.frame{margin:18px 0}</style>",
        "<h1>Stage 0 — wall → pixel projection</h1>",
        f"<p>Walls: {len(results)} · "
        + " · ".join(
            f"<span class='pill' style='background:{_BAND_COLOR[b]}'>{b}: {counts.get(b, 0)}</span>"
            for b in ("high", "medium", "low")
        )
        + "</p>",
    ]

    # Summary table (obvious which wall / frame / band — requirement #3).
    parts.append(
        "<table><tr><th>wall</th><th>frame</th><th>band</th><th>conf</th>"
        "<th>angle°</th><th>in-frame</th><th>orient</th><th>sensor→jpeg</th></tr>"
    )
    for r in results:
        band = r.get("band", "low")
        orient = r.get("orientation", {})
        parts.append(
            "<tr>"
            f"<td>{html.escape(r['wall_id'])}</td>"
            f"<td>{html.escape(str(r.get('selected_frame')))}</td>"
            f"<td><span class='pill' style='background:{_BAND_COLOR[band]}'>{band}</span></td>"
            f"<td>{r.get('confidence', 0)}</td>"
            f"<td>{r.get('view_angle_deg', '-')}</td>"
            f"<td>{r.get('corners_in_frame', '-')}/4</td>"
            f"<td>{html.escape(str(orient.get('mode', '-')))} "
            f"(res={orient.get('resolved', '-')})</td>"
            f"<td>{r.get('sensor_wh', '-')}→{r.get('jpeg_wh', '-')}</td>"
            "</tr>"
        )
    parts.append("</table>")

    # One overlay per source frame, drawing every wall that selected it.
    by_frame: Dict[str, List[Dict[str, Any]]] = {}
    for r in results:
        name = r.get("selected_frame")
        if name and name in images and r.get("wall_corners_jpeg_px"):
            by_frame.setdefault(name, []).append(r)

    for name, walls in by_frame.items():
        jw, jh = jpeg_sizes.get(name, (0, 0))
        parts.append(f"<div class='frame'><h2>{html.escape(name)}</h2>")
        parts.append(
            f"<svg viewBox='0 0 {jw} {jh}' xmlns='http://www.w3.org/2000/svg'>"
            f"<image href='{_data_uri(images[name])}' x='0' y='0' width='{jw}' height='{jh}'/>"
        )
        for r in walls:
            color = _BAND_COLOR[r.get("band", "low")]
            outline = _poly(r["wall_corners_jpeg_px"])
            parts.append(
                f"<polygon points='{outline}' fill='{color}' fill-opacity='0.18' "
                f"stroke='{color}' stroke-width='4'/>"
            )
            for op in r.get("openings", []):
                op_pts = _poly(op.get("corners_jpeg_px", []))
                if op_pts:
                    parts.append(
                        f"<polygon points='{op_pts}' fill='none' stroke='#3498db' "
                        f"stroke-width='3' stroke-dasharray='10 6'/>"
                    )
            # Wall id + band label at the first visible corner.
            anchor = next((p for p in r["wall_corners_jpeg_px"] if p), [10, 30])
            label = f"{r['wall_id']} · {r.get('band')} {r.get('confidence', '')}"
            parts.append(
                f"<text x='{anchor[0]}' y='{max(anchor[1] - 8, 16)}' fill='{color}' "
                f"font-size='30' font-weight='700' "
                f"style='paint-order:stroke;stroke:#000;stroke-width:5px'>{html.escape(label)}</text>"
            )
        parts.append("</svg></div>")

    walls_no_frame = [r for r in results if not r.get("selected_frame")]
    if walls_no_frame:
        parts.append("<h2>No usable frame (fallback/skip)</h2><ul>")
        for r in walls_no_frame:
            parts.append(f"<li>{html.escape(r['wall_id'])} — {html.escape(r.get('reason', ''))}</li>")
        parts.append("</ul>")

    return "".join(parts)
