@testable import BuildPilot
import CoreGraphics
import simd
import XCTest

/// Analytic wall geometry — the on-device mirror of the backend projection.
/// Same scene as backend `test_wall_projection` (a 2×2 m wall 3 m ahead), so a
/// frame the phone accepts is the frame Stage 0 scores HIGH/MEDIUM. No ARKit
/// session or camera is involved — pure transforms in, numbers out.
final class WallGeometryTests: XCTestCase {
    /// A 2×2 m wall centred 3 m in front of the origin, facing +Z (toward a
    /// camera at the origin looking −Z).
    private let wall = WallQuad(
        id: "w1",
        center: SIMD3(0, 0, -3),
        xAxis: SIMD3(1, 0, 0),
        yAxis: SIMD3(0, 1, 0),
        normal: SIMD3(0, 0, 1),
        halfWidth: 1, halfHeight: 1
    )

    /// Identity camera pose (at origin, looking −Z).
    private let cameraIdentity = matrix_identity_float4x4

    /// fx=fy=1000, cx=960, cy=540.
    private let intrinsics = simd_float3x3(columns: (
        SIMD3<Float>(1000, 0, 0),
        SIMD3<Float>(0, 1000, 0),
        SIMD3<Float>(960, 540, 1)
    ))

    func testWallCentreProjectsToImageCentre() {
        let p = WallGeometry.projectToSensor(wall.center, cameraTransform: cameraIdentity, intrinsics: intrinsics)
        let u = try! XCTUnwrap(p)
        XCTAssertEqual(u.x, 960, accuracy: 0.01)
        XCTAssertEqual(u.y, 540, accuracy: 0.01)
    }

    func testCornerProjection() {
        // Corner (+1,+1,-3): u = 1000*(1/3)+960, v = 1000*(-1/3)+540.
        let corner = SIMD3<Float>(1, 1, -3)
        let p = try! XCTUnwrap(WallGeometry.projectToSensor(corner, cameraTransform: cameraIdentity, intrinsics: intrinsics))
        XCTAssertEqual(p.x, 1293.33, accuracy: 0.1)
        XCTAssertEqual(p.y, 206.67, accuracy: 0.1)
    }

    func testPointBehindCameraDoesNotProject() {
        XCTAssertNil(WallGeometry.projectToSensor(SIMD3(0, 0, 3), cameraTransform: cameraIdentity, intrinsics: intrinsics))
    }

    func testFacingWallHeadOn() {
        XCTAssertEqual(WallGeometry.facingWall(cameraTransform: cameraIdentity, walls: [wall]), "w1")
    }

    func testViewAngleAndDistanceHeadOn() {
        XCTAssertEqual(WallGeometry.viewAngleDegrees(cameraTransform: cameraIdentity, wall: wall), 0, accuracy: 0.01)
        XCTAssertEqual(WallGeometry.distanceM(cameraTransform: cameraIdentity, wall: wall), 3, accuracy: 0.001)
    }

    func testAllCornersInFrameHeadOn() {
        let n = WallGeometry.cornersInFrame(
            wall, cameraTransform: cameraIdentity, intrinsics: intrinsics, sensor: CGSize(width: 1920, height: 1080)
        )
        XCTAssertEqual(n, 4)
    }

    func testObliqueViewAngleIs45() {
        // Camera rotated 45° about Y → forward (−sin,0,−cos); |forward·normal| = cos45.
        let c = Float(cos(Double.pi / 4)), s = Float(sin(Double.pi / 4))
        let rotY = simd_float4x4(columns: (
            SIMD4<Float>(c, 0, -s, 0),
            SIMD4<Float>(0, 1, 0, 0),
            SIMD4<Float>(s, 0, c, 0),
            SIMD4<Float>(0, 0, 0, 1)
        ))
        XCTAssertEqual(WallGeometry.viewAngleDegrees(cameraTransform: rotY, wall: wall), 45, accuracy: 0.5)
    }

    func testGrazingWallIsNotFaced() {
        // A wall whose normal is perpendicular to the camera forward isn't hit
        // by the forward ray (parallel to the wall plane).
        let sideWall = WallQuad(
            id: "w2", center: SIMD3(2, 0, -3), xAxis: SIMD3(0, 0, 1), yAxis: SIMD3(0, 1, 0),
            normal: SIMD3(1, 0, 0), halfWidth: 1, halfHeight: 1
        )
        XCTAssertNil(WallGeometry.facingWall(cameraTransform: cameraIdentity, walls: [sideWall]))
    }
}
