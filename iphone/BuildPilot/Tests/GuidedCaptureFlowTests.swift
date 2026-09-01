import XCTest
@testable import BuildPilot

final class GuidedCaptureFlowTests: XCTestCase {
    private let openStatus = WallLoopStatus.open(
        openEnds: [OpenWallEnd(wallId: "w1", end: .start, position: .zero,
                               nearestWallId: "w2", gapM: 3.0)],
        wallCount: 2
    )

    func testCleanPath() {
        var flow = GuidedCaptureFlow()
        XCTAssertEqual(flow.phase, .scanning)
        XCTAssertFalse(flow.rescan())  // no rescan mid-scan
        flow.scanEnded(.closed(wallCount: 4))
        XCTAssertEqual(flow.phase, .review)
        XCTAssertTrue(flow.canFinishCleanly)
        XCTAssertFalse(flow.canFinishFlagged)
        XCTAssertFalse(flow.rescan())  // nothing to rescan
    }

    func testOpenLoopOffersRescanAndFlaggedFinishOnly() {
        var flow = GuidedCaptureFlow()
        flow.scanEnded(openStatus)
        XCTAssertFalse(flow.canFinishCleanly)
        XCTAssertTrue(flow.canFinishFlagged)   // never trap the user…
        XCTAssertEqual(flow.openEnds.count, 1) // …but point at the gap
        XCTAssertTrue(flow.rescan())
        XCTAssertEqual(flow.phase, .rescanning)
        XCTAssertEqual(flow.rescanCount, 1)
        // The rescan closed the loop.
        flow.scanEnded(.closed(wallCount: 4))
        XCTAssertTrue(flow.canFinishCleanly)
    }

    func testRepeatedRescansCount() {
        var flow = GuidedCaptureFlow()
        flow.scanEnded(openStatus)
        flow.rescan()
        flow.scanEnded(openStatus)  // still open
        flow.rescan()
        XCTAssertEqual(flow.rescanCount, 2)
        XCTAssertTrue(flow.canFinishFlagged == false)  // mid-rescan: no finish
    }

    func testScanEndedIgnoredWhileReviewing() {
        var flow = GuidedCaptureFlow()
        flow.scanEnded(openStatus)
        flow.scanEnded(.closed(wallCount: 4))  // stray event: ignored
        XCTAssertFalse(flow.loopClosed)
    }
}
