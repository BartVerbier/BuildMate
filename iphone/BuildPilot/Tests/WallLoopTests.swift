import XCTest
import simd
@testable import BuildPilot

/// Synthetic geometry for the WallLoop port. The real-scan agreement with the
/// backend lives in WallLoopRealScanTests (generated); these pin the basics
/// in shapes a human can check by hand.
final class WallLoopTests: XCTestCase {
    /// A wall footprint straight from endpoints (bypasses transform decoding,
    /// which the generated real-scan tests cover).
    private func wall(_ id: String, _ sx: Double, _ sz: Double,
                      _ ex: Double, _ ez: Double, h: Double = 2.5) -> WallFootprint {
        WallFootprint(id: id, start: SIMD2(sx, sz), end: SIMD2(ex, ez), heightM: h)
    }

    // 5x3 rectangle, corners meeting exactly — the synthetic baseline room.
    private var closedRoom: [WallFootprint] {
        [
            wall("w1", -2.5, -1.5, 2.5, -1.5),
            wall("w2", 2.5, -1.5, 2.5, 1.5),
            wall("w3", 2.5, 1.5, -2.5, 1.5),
            wall("w4", -2.5, 1.5, -2.5, -1.5),
        ]
    }

    func testClosedRectangleAssessesClosed() {
        XCTAssertEqual(WallLoop.assess(closedRoom), .closed(wallCount: 4))
        XCTAssertTrue(WallLoop.openEnds(closedRoom).isEmpty)
    }

    func testCornersJoinWithinToleranceNotBeyond() {
        var room = closedRoom
        // Shift w4 by 0.29 m: still a joined corner (tolerance 0.30).
        room[3] = wall("w4", -2.5, 1.79, -2.5, -1.21)
        XCTAssertTrue(WallLoop.openEnds(room).isEmpty)
        // 0.31 m: two corners come apart (both ends of the moved wall).
        room[3] = wall("w4", -2.5, 1.81, -2.5, -1.19)
        XCTAssertEqual(WallLoop.openEnds(room).count, 4)
    }

    func testTwoWallLShapeHasTwoOpenEnds() {
        // The signature field-scan failure: one long + one short wall.
        let room = [
            wall("w1", -3.0, 0.0, 3.0, 0.0),
            wall("w2", 3.0, 0.0, 3.0, 2.0),
        ]
        let open = WallLoop.openEnds(room)
        XCTAssertEqual(open.count, 2)
        // The two free ends, each pointing at the other wall as nearest.
        XCTAssertEqual(Set(open.map(\.wallId)), ["w1", "w2"])
        if case .open(let ends, let count) = WallLoop.assess(room) {
            XCTAssertEqual(ends.count, 2)
            XCTAssertEqual(count, 2)
        } else {
            XCTFail("two walls must never assess closed")
        }
    }

    func testMissingWallLeavesLocatedGap() {
        let room = Array(closedRoom.dropLast())  // no w4: west side open
        let open = WallLoop.openEnds(room)
        XCTAssertEqual(open.count, 2)
        XCTAssertEqual(Set(open.map(\.wallId)), ["w1", "w3"])
        // The gap positions are the two west corners — that is what the UI
        // points the user at.
        XCTAssertTrue(open.allSatisfy { $0.position.x == -2.5 })
        XCTAssertEqual(open.first?.gapM, 3.0)
    }

    func testSplitWallSurfaceIsNotAFalseGap() {
        // RoomPlan emits the south wall twice (colinear, overlapping, same
        // height). The duplicate is excluded; the loop still reads closed.
        var room = closedRoom
        room.append(wall("w5", -2.4, -1.5, 2.4, -1.5))
        XCTAssertEqual(WallLoop.duplicates(room), ["w5": "w1"])
        XCTAssertEqual(WallLoop.assess(room), .closed(wallCount: 4))
    }

    func testTwoParallelWallsAloneAreNotDuplicates() {
        // Opposite sides of a room: parallel but 3 m apart — never merged.
        let room = [
            wall("w1", -2.5, -1.5, 2.5, -1.5),
            wall("w3", 2.5, 1.5, -2.5, 1.5),
        ]
        XCTAssertTrue(WallLoop.duplicates(room).isEmpty)
    }

    func testNoWalls() {
        XCTAssertEqual(WallLoop.assess([]), .noWalls)
    }

    func testFootprintsDecodeTransform() {
        // A 4 m wall centred at (1, -2), rotated 90°: local x = world z.
        var t = matrix_identity_float4x4
        t.columns.0 = SIMD4(0, 0, 1, 0)
        t.columns.3 = SIMD4(1, 0, -2, 1)
        let f = WallLoop.footprints(transforms: [t], dimensions: [SIMD3(4, 2.4, 0)])
        XCTAssertEqual(f.count, 1)
        XCTAssertEqual(f[0].id, "w1")
        XCTAssertEqual(f[0].start.x, 1.0, accuracy: 1e-6)
        XCTAssertEqual(f[0].start.y, -4.0, accuracy: 1e-6)
        XCTAssertEqual(f[0].end.y, 0.0, accuracy: 1e-6)
        XCTAssertEqual(f[0].heightM, 2.4, accuracy: 1e-6)
        XCTAssertEqual(f[0].lengthM, 4.0, accuracy: 1e-6)
    }
}
