import ARKit
import RoomPlan
import simd

/// Pure, testable wall↔camera geometry — the on-device mirror of the backend
/// `gaze`/`wall_projection` math, so a frame the phone judges "good" is the
/// same frame Stage 0 would score HIGH/MEDIUM. Used by the AR-continuity spike
/// and (later) the guided per-wall capture. No ARKit session state here — just
/// transforms in, numbers out — which is what makes it unit-testable.
struct WallQuad {
    let id: String            // positional "w1"… matching the backend's wall order
    let center: SIMD3<Float>
    let xAxis: SIMD3<Float>   // unit width direction
    let yAxis: SIMD3<Float>   // unit height direction
    let normal: SIMD3<Float>  // unit wall normal
    let halfWidth: Float
    let halfHeight: Float

    /// World-space corners in Z-order [(-,-),(-,+),(+,-),(+,+)] — same ordering
    /// as the backend `_WallRect.corners()`.
    var corners: [SIMD3<Float>] {
        var out: [SIMD3<Float>] = []
        for su in [Float(-1), 1] {
            for sv in [Float(-1), 1] {
                out.append(center + su * halfWidth * xAxis + sv * halfHeight * yAxis)
            }
        }
        return out
    }

    /// A closed outline loop (proper winding) for drawing.
    var cornerLoop: [SIMD3<Float>] {
        let c = corners
        return [c[0], c[1], c[3], c[2]]
    }

    var areaM2: Float { (2 * halfWidth) * (2 * halfHeight) }
}

enum WallGeometry {
    // Match the backend's ray-hit gate (pipelines/gaze.py).
    static let minHitDistanceM: Float = 0.3
    static let maxHitDistanceM: Float = 8.0
    static let edgeTolerance: Float = 1.05

    /// Wall quads from a CapturedRoom, ids "w1"… in wall order (the same order
    /// the CapturedRoom JSON encodes, so ids match the backend end-to-end).
    static func quads(from walls: [CapturedRoom.Surface]) -> [WallQuad] {
        walls.enumerated().map { index, wall in
            let t = wall.transform
            return WallQuad(
                id: "w\(index + 1)",
                center: SIMD3(t.columns.3.x, t.columns.3.y, t.columns.3.z),
                xAxis: simd_normalize(SIMD3(t.columns.0.x, t.columns.0.y, t.columns.0.z)),
                yAxis: simd_normalize(SIMD3(t.columns.1.x, t.columns.1.y, t.columns.1.z)),
                normal: simd_normalize(SIMD3(t.columns.2.x, t.columns.2.y, t.columns.2.z)),
                halfWidth: wall.dimensions.x / 2,
                halfHeight: wall.dimensions.y / 2
            )
        }
    }

    /// Project a world point into sensor pixels (intrinsics + camera pose).
    /// Returns nil if behind the camera. Mirrors backend `_project`: the camera
    /// looks along −Z (transform column 2 is +Z / "backward").
    static func projectToSensor(
        _ p: SIMD3<Float>, cameraTransform t: simd_float4x4, intrinsics k: simd_float3x3
    ) -> SIMD2<Float>? {
        let cam = SIMD3(t.columns.3.x, t.columns.3.y, t.columns.3.z)
        let right = SIMD3(t.columns.0.x, t.columns.0.y, t.columns.0.z)
        let up = SIMD3(t.columns.1.x, t.columns.1.y, t.columns.1.z)
        let back = SIMD3(t.columns.2.x, t.columns.2.y, t.columns.2.z)
        let rel = p - cam
        let x = simd_dot(rel, right)
        let y = simd_dot(rel, up)
        let z = simd_dot(rel, back)
        if z >= -1e-6 { return nil } // behind the camera
        let fx = k.columns.0.x, fy = k.columns.1.y
        let cx = k.columns.2.x, cy = k.columns.2.y
        let u = fx * (x / -z) + cx
        let v = fy * (-y / -z) + cy
        return SIMD2(u, v)
    }

    /// The wall the camera's forward (−Z) ray hits first, or nil. Mirrors
    /// `resolve_pose` + `_WallRect.ray_hit`.
    static func facingWall(cameraTransform t: simd_float4x4, walls: [WallQuad]) -> String? {
        let origin = SIMD3(t.columns.3.x, t.columns.3.y, t.columns.3.z)
        let forward = -SIMD3(t.columns.2.x, t.columns.2.y, t.columns.2.z)
        var bestT = Float.greatestFiniteMagnitude
        var bestId: String?
        for wall in walls {
            let denom = simd_dot(forward, wall.normal)
            if abs(denom) < 1e-6 { continue }
            let hitT = simd_dot(wall.center - origin, wall.normal) / denom
            if hitT < minHitDistanceM || hitT > maxHitDistanceM { continue }
            let hit = origin + hitT * forward
            let local = hit - wall.center
            let u = simd_dot(local, wall.xAxis)
            let v = simd_dot(local, wall.yAxis)
            if abs(u) <= wall.halfWidth * edgeTolerance,
               abs(v) <= wall.halfHeight * edgeTolerance,
               hitT < bestT {
                bestT = hitT
                bestId = wall.id
            }
        }
        return bestId
    }

    /// Angle between the camera's viewing direction and the wall normal line.
    /// 0° = head-on, 90° = grazing. Sign of the normal is ignored.
    static func viewAngleDegrees(cameraTransform t: simd_float4x4, wall: WallQuad) -> Float {
        let forward = simd_normalize(-SIMD3(t.columns.2.x, t.columns.2.y, t.columns.2.z))
        let cos = abs(simd_dot(forward, wall.normal))
        return acos(max(0, min(1, cos))) * 180 / .pi
    }

    static func distanceM(cameraTransform t: simd_float4x4, wall: WallQuad) -> Float {
        let cam = SIMD3(t.columns.3.x, t.columns.3.y, t.columns.3.z)
        return simd_length(wall.center - cam)
    }

    /// How many of the wall's 4 corners fall inside the sensor image bounds.
    static func cornersInFrame(
        _ wall: WallQuad, cameraTransform t: simd_float4x4,
        intrinsics k: simd_float3x3, sensor: CGSize
    ) -> Int {
        var count = 0
        for corner in wall.corners {
            guard let p = projectToSensor(corner, cameraTransform: t, intrinsics: k) else { continue }
            if p.x >= 0, p.x <= Float(sensor.width), p.y >= 0, p.y <= Float(sensor.height) {
                count += 1
            }
        }
        return count
    }
}
