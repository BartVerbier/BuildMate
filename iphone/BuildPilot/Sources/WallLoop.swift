import simd

/// Ground-plane wall-loop assessment — the on-device mirror of the backend's
/// Decision 34 open-edge detection (`measurement.py: _aligned_segments`,
/// `_duplicate_wall_map`, `_open_wall_edges`). Runs live during capture so the
/// guided flow can point the user at the exact gap while they are still in the
/// room. The BACKEND stays authoritative: this is guidance, its verdict is
/// never uploaded and never touches a measurement or a price.
///
/// Tolerances are the backend's, verbatim — if the two disagree on a real
/// scan, that is a bug (WallLoopRealScanTests pins them together).
struct WallFootprint: Equatable {
    let id: String            // positional "w1"… matching the backend wall order
    let start: SIMD2<Double>  // world ground plane (x, z), metres
    let end: SIMD2<Double>
    let heightM: Double

    var lengthM: Double { simd_length(end - start) }
}

/// One end of the wall loop that connects to nothing — a concrete rescan
/// target: which wall, which end, where, and how far the nearest wall end is.
struct OpenWallEnd: Equatable {
    enum End: String { case start, end }
    let wallId: String
    let end: End
    let position: SIMD2<Double>
    let nearestWallId: String?
    let gapM: Double?
}

enum WallLoopStatus: Equatable {
    case noWalls
    /// The loop does not close; `openEnds` locates every gap.
    case open(openEnds: [OpenWallEnd], wallCount: Int)
    /// Every wall end joins another within tolerance and there are enough
    /// walls to enclose anything (a polygon needs 3).
    case closed(wallCount: Int)
}

enum WallLoop {
    // Backend constants, verbatim (measurement.py). Do not tune here —
    // retuning happens against ground truth, on the backend, first.
    static let cornerJoinToleranceM = 0.30
    static let duplicateLineDistanceM = 0.20
    static let duplicateOverlapRatio = 0.8
    static let duplicateHeightToleranceM = 0.30

    /// Footprints from raw wall transforms: endpoints are centre ± width/2
    /// along the wall's local x axis, projected to world (x, z). Mirrors
    /// `_aligned_segments`.
    static func footprints(
        transforms: [simd_float4x4], dimensions: [SIMD3<Float>]
    ) -> [WallFootprint] {
        zip(transforms, dimensions).enumerated().map { index, wall in
            let (t, dims) = wall
            let half = Double(dims.x) / 2.0
            let xAxis = SIMD2(Double(t.columns.0.x), Double(t.columns.0.z))
            let centre = SIMD2(Double(t.columns.3.x), Double(t.columns.3.z))
            return WallFootprint(
                id: "w\(index + 1)",
                start: centre - half * xAxis,
                end: centre + half * xAxis,
                heightM: Double(dims.y)
            )
        }
    }

    /// Walls that duplicate another (colinear, overlapping, same height):
    /// id → id of the wall it duplicates. The longer wall is kept. Mirrors
    /// `_duplicate_wall_map` so a split RoomPlan surface never reads as a gap.
    static func duplicates(_ footprints: [WallFootprint]) -> [String: String] {
        var result: [String: String] = [:]
        // Longest wall first; ties keep original wall order (backend sorts by
        // (-length, index) — NOT by id string, which would put w10 before w2).
        let order = footprints.enumerated()
            .filter { $0.element.lengthM > 0 }
            .sorted { a, b in
                a.element.lengthM != b.element.lengthM
                    ? a.element.lengthM > b.element.lengthM
                    : a.offset < b.offset
            }
            .map(\.element)
        for (position, a) in order.enumerated() {
            if result[a.id] != nil { continue }
            let d = a.end - a.start
            let lengthSq = simd_length_squared(d)
            for b in order.dropFirst(position + 1) {
                if result[b.id] != nil { continue }
                if abs(a.heightM - b.heightM) > duplicateHeightToleranceM { continue }
                let offLine = max(
                    distanceToLine(b.start, a.start, a.end),
                    distanceToLine(b.end, a.start, a.end)
                )
                if offLine > duplicateLineDistanceM { continue }
                // Overlap of b's extent projected onto a's line.
                let t0 = simd_dot(b.start - a.start, d) / lengthSq
                let t1 = simd_dot(b.end - a.start, d) / lengthSq
                let overlap = max(0, min(max(t0, t1), 1) - max(min(t0, t1), 0)) * a.lengthM
                if overlap >= duplicateOverlapRatio * b.lengthM {
                    result[b.id] = a.id
                }
            }
        }
        return result
    }

    /// Endpoints with no joined partner on another wall, duplicates excluded.
    /// Mirrors `_open_wall_edges`: an end is joined when the nearest OTHER
    /// wall's endpoint is within the corner tolerance.
    static func openEnds(_ footprints: [WallFootprint]) -> [OpenWallEnd] {
        let excluded = Set(duplicates(footprints).keys)
        let counted = footprints.filter { !excluded.contains($0.id) && $0.lengthM > 0 }
        struct Endpoint { let wallId: String; let end: OpenWallEnd.End; let point: SIMD2<Double> }
        var endpoints: [Endpoint] = []
        for wall in counted {
            endpoints.append(Endpoint(wallId: wall.id, end: .start, point: wall.start))
            endpoints.append(Endpoint(wallId: wall.id, end: .end, point: wall.end))
        }
        var result: [OpenWallEnd] = []
        for candidate in endpoints {
            var best: Double?
            var bestWall: String?
            for other in endpoints where other.wallId != candidate.wallId {
                let gap = simd_length(candidate.point - other.point)
                if best == nil || gap < best! {
                    best = gap
                    bestWall = other.wallId
                }
            }
            if let best, best <= cornerJoinToleranceM { continue } // joined corner
            result.append(OpenWallEnd(
                wallId: candidate.wallId,
                end: candidate.end,
                position: candidate.point,
                nearestWallId: bestWall,
                gapM: best.map { ($0 * 100).rounded() / 100 }
            ))
        }
        return result
    }

    static func assess(_ footprints: [WallFootprint]) -> WallLoopStatus {
        let excluded = Set(duplicates(footprints).keys)
        let counted = footprints.filter { !excluded.contains($0.id) && $0.lengthM > 0 }
        if counted.isEmpty { return .noWalls }
        let open = openEnds(footprints)
        if open.isEmpty && counted.count >= 3 { return .closed(wallCount: counted.count) }
        return .open(openEnds: open, wallCount: counted.count)
    }

    private static func distanceToLine(
        _ p: SIMD2<Double>, _ a: SIMD2<Double>, _ b: SIMD2<Double>
    ) -> Double {
        let d = b - a
        let lengthSq = simd_length_squared(d)
        if lengthSq == 0 { return simd_length(p - a) }
        let t = simd_dot(p - a, d) / lengthSq
        return simd_length(p - (a + t * d))
    }
}
