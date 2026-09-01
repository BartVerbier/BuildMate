@testable import BuildPilot
import XCTest

/// The visit-start sequence: details → light check → report → Start Visit.
/// Pure state machine — no SwiftUI, no ARKit.
final class VisitSetupFlowTests: XCTestCase {
    func testStartsOnDetails() {
        XCTAssertEqual(VisitSetupFlow().step, .details)
    }

    func testInvalidCustomerCannotAdvance() {
        // The light check (and its camera) must not start until the form
        // is complete.
        var flow = VisitSetupFlow()
        XCTAssertFalse(flow.advanceToLightCheck(customerValid: false))
        XCTAssertEqual(flow.step, .details)
    }

    func testHappyPathSequence() {
        var flow = VisitSetupFlow()
        XCTAssertTrue(flow.advanceToLightCheck(customerValid: true))
        XCTAssertEqual(flow.step, .lightCheck)
        flow.surveyEnded() // Done Checking (or fail-open unavailable)
        XCTAssertEqual(flow.step, .report) // report ALWAYS precedes Start Visit
    }

    func testSurveyEndCannotSkipTheLightCheck() {
        // A stray terminal gate status while typing details must not jump
        // the flow forward.
        var flow = VisitSetupFlow()
        flow.surveyEnded()
        XCTAssertEqual(flow.step, .details)
    }

    func testBackToDetailsFromLightCheckOnly() {
        var flow = VisitSetupFlow()
        flow.advanceToLightCheck(customerValid: true)
        flow.backToDetails()
        XCTAssertEqual(flow.step, .details)
        flow.backToDetails() // no-op outside lightCheck
        XCTAssertEqual(flow.step, .details)
    }

    func testCheckAgainReturnsToTheWalk() {
        var flow = VisitSetupFlow()
        flow.advanceToLightCheck(customerValid: true)
        flow.surveyEnded()
        flow.reWalk() // Check Light Again from the report
        XCTAssertEqual(flow.step, .lightCheck)
        flow.surveyEnded()
        XCTAssertEqual(flow.step, .report)
    }

    func testReWalkOnlyFromReport() {
        var flow = VisitSetupFlow()
        flow.reWalk()
        XCTAssertEqual(flow.step, .details)
    }
}

/// The report's low-light moment counter (on the gate controller) and the
/// no-scope notice (Part B): both pure logic.
final class LightReportAndScopeNoticeTests: XCTestCase {
    @MainActor
    func testLowLightMomentsCountDistinctDips() {
        // good → dark → good → dim → dark → good = 2 distinct dips (the
        // dim→dark slide inside the second stretch counts once).
        let gate = LightingGateController()
        gate.activate()
        gate.ingest(lumens: 800, at: 0)
        gate.ingest(lumens: 80, at: 1) // dip 1
        gate.ingest(lumens: 900, at: 2)
        gate.ingest(lumens: 300, at: 3) // dip 2 (dim…)
        gate.ingest(lumens: 90, at: 4) // …sliding to dark, same dip
        gate.ingest(lumens: 850, at: 5)
        XCTAssertEqual(gate.lowLightMoments, 2)
        gate.finishSurvey()
        XCTAssertEqual(gate.worstLumens, 80)
        gate.stop()
    }

    @MainActor
    func testWalkStartingDarkCountsAsOneMoment() {
        let gate = LightingGateController()
        gate.activate()
        gate.ingest(lumens: 90, at: 0) // starts in the dark
        gate.ingest(lumens: 85, at: 1)
        XCTAssertEqual(gate.lowLightMoments, 1)
        gate.stop()
    }

    @MainActor
    func testCheckAgainResetsTheMomentCount() {
        let gate = LightingGateController()
        gate.activate()
        gate.ingest(lumens: 80, at: 0)
        gate.finishSurvey()
        gate.checkAgain()
        XCTAssertEqual(gate.lowLightMoments, 0)
        gate.stop()
    }

    // MARK: - Part B: silent no-scope visits fail loudly

    func testEmptyScopeProducesTheNotice() {
        let requirements = RequirementExtraction(
            scopeOfWork: [], exclusions: [], preparationRequired: [],
            specialNotes: [], paintScope: PaintScope(walls: true, ceiling: true),
            paintedWallIds: nil, transcriptAvailable: true
        )
        XCTAssertEqual(ScopeNotice.message(for: requirements), ScopeNotice.noScopeCaptured)
    }

    func testMissingRequirementsProduceTheNotice() {
        XCTAssertEqual(ScopeNotice.message(for: nil), ScopeNotice.noScopeCaptured)
    }

    func testRealScopeProducesNoNotice() {
        let requirements = RequirementExtraction(
            scopeOfWork: ["Paint the walls sage green"], exclusions: [],
            preparationRequired: [], specialNotes: [],
            paintScope: PaintScope(walls: true, ceiling: false),
            paintedWallIds: nil, transcriptAvailable: true
        )
        XCTAssertNil(ScopeNotice.message(for: requirements))
    }
}

/// The whole-room-fallback warning: a specific-wall request the backend
/// couldn't ground must read as WHOLE ROOM until walls are chosen — and
/// clear itself the moment they are.
final class WallScopeAlertTests: XCTestCase {
    private func requirements(
        ids: [String]?, reference: String?
    ) -> RequirementExtraction {
        RequirementExtraction(
            scopeOfWork: ["Paint wall with TV and cabinets"], exclusions: [],
            preparationRequired: [], specialNotes: [],
            paintScope: PaintScope(walls: true, ceiling: false),
            paintedWallIds: ids, unresolvedWallReference: reference,
            transcriptAvailable: true
        )
    }

    func testUngroundedReferenceRaisesTheAlert() {
        // The 2026-08-16 case: "the wall with the TV", no ids → the quote
        // covers everything and must say so, naming the customer's words.
        let message = WallScopeAlert.message(for: requirements(ids: [], reference: "the wall with the TV"))
        XCTAssertNotNil(message)
        XCTAssertTrue(message!.contains("the wall with the TV"))
        XCTAssertTrue(message!.contains("WHOLE ROOM"))
    }

    func testChoosingWallsClearsTheAlert() {
        // After Edit Plan picks the wall(s) and the re-estimate returns,
        // paintedWallIds is non-empty — the alert must disappear.
        XCTAssertNil(WallScopeAlert.message(for: requirements(ids: ["w4"], reference: "the wall with the TV")))
    }

    func testExplicitWholeRoomRaisesNoFalseAlarm() {
        // "Paint everything" legitimately means empty ids and no reference.
        XCTAssertNil(WallScopeAlert.message(for: requirements(ids: [], reference: nil)))
        XCTAssertNil(WallScopeAlert.message(for: requirements(ids: nil, reference: nil)))
    }

    func testMissingRequirementsRaiseNoAlert() {
        XCTAssertNil(WallScopeAlert.message(for: nil))
    }
}
