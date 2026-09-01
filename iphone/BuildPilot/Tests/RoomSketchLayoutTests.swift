import XCTest
import simd
@testable import BuildPilot

final class RoomSketchLayoutTests: XCTestCase {
    func testFitPreservesAspectAndCentres() {
        // A 6x3 m room into a 200x200 canvas with 18 pt padding: the wide
        // axis governs the scale; the narrow axis is centred.
        let points = [SIMD2(0.0, 0.0), SIMD2(6.0, 0.0), SIMD2(6.0, 3.0), SIMD2(0.0, 3.0)]
        let fit = RoomSketchLayout.fit(points: points, into: CGSize(width: 200, height: 200))!
        XCTAssertEqual(fit.scale, (200.0 - 36) / 6.0, accuracy: 1e-9)
        let a = fit.point(SIMD2(0.0, 0.0))
        let b = fit.point(SIMD2(6.0, 3.0))
        XCTAssertEqual(a.x, 18, accuracy: 1e-6)                 // padded to the edge
        XCTAssertEqual(b.x, 182, accuracy: 1e-6)
        // Vertical span (3 m ≙ 82 pt) centred in 200 pt.
        XCTAssertEqual((a.y + b.y) / 2, 100, accuracy: 1e-6)
        XCTAssertEqual(b.y - a.y, 3 * fit.scale, accuracy: 1e-6)
    }

    func testDegenerateInputsReturnNil() {
        XCTAssertNil(RoomSketchLayout.fit(points: [], into: CGSize(width: 200, height: 200)))
        XCTAssertNil(RoomSketchLayout.fit(
            points: [SIMD2(1.0, 1.0)], into: CGSize(width: 10, height: 10)))  // smaller than padding
    }

    func testSinglePointStillFits() {
        // One point (zero span) must not divide by zero; it lands centred.
        let fit = RoomSketchLayout.fit(points: [SIMD2(4.0, -2.0)], into: CGSize(width: 100, height: 100))!
        let p = fit.point(SIMD2(4.0, -2.0))
        XCTAssertEqual(p.x, 50, accuracy: 0.5)
        XCTAssertEqual(p.y, 50, accuracy: 0.5)
    }
}
