@testable import BuildPilot
import XCTest

/// The lighting survey's threshold and lifecycle logic with synthetic
/// ambientIntensity values — no ARKit, no camera, no device. The ARSession
/// only ever feeds numbers into the controller, so this covers every
/// gating decision it can make.
final class LightingGateTests: XCTestCase {
    // MARK: - the three bands (thresholds: proceed ≥ 500, hold < 200)

    func testBandBoundaries() {
        XCTAssertEqual(LightBand.forReading(500), .good) // at proceed threshold
        XCTAssertEqual(LightBand.forReading(1000), .good) // Apple's "neutral"
        XCTAssertEqual(LightBand.forReading(499), .dim) // just under proceed
        XCTAssertEqual(LightBand.forReading(200), .dim) // at hold line
        XCTAssertEqual(LightBand.forReading(199), .dark) // just under hold
        XCTAssertEqual(LightBand.forReading(0), .dark)
        XCTAssertEqual(LightBand.forReading(nil), .unknown)
    }

    func testBandsFollowTheNamedConstants() {
        // The bands must move if the campaign retunes the constants —
        // guard against a hard-coded 500/200 hiding somewhere.
        XCTAssertEqual(LightBand.forReading(LightThresholds.proceedMinLumens), .good)
        XCTAssertEqual(LightBand.forReading(LightThresholds.proceedMinLumens - 1), .dim)
        XCTAssertEqual(LightBand.forReading(LightThresholds.holdBelowLumens), .dim)
        XCTAssertEqual(LightBand.forReading(LightThresholds.holdBelowLumens - 1), .dark)
    }

    // MARK: - the walk: worst reading drives the verdict

    @MainActor
    func testDarkCornerSticksEvenAfterReturningToGoodLight() {
        // THE core scenario: bright room, one covered/dark corner, then
        // back into bright light before tapping Done. The verdict must be
        // the corner, not the average and not the final reading.
        let gate = LightingGateController()
        gate.activate() // start() minus the ARSession (unsupported off-device)
        gate.ingest(lumens: 900, at: 0) // lit area
        XCTAssertEqual(gate.status, .surveying(worst: .good))
        gate.ingest(lumens: 60, at: 1) // the dark corner
        XCTAssertEqual(gate.status, .surveying(worst: .dark))
        gate.ingest(lumens: 950, at: 2) // back in good light
        gate.ingest(lumens: 980, at: 3)
        XCTAssertEqual(gate.status, .surveying(worst: .dark)) // corner sticks
        XCTAssertEqual(gate.worstLumens, 60)
        gate.finishSurvey()
        XCTAssertEqual(gate.status, .complete(worst: .dark))
        XCTAssertFalse(gate.status.allowsStart) // refuse band: Start held
        XCTAssertEqual(gate.status.message, LightingGateCopy.moreLightNeeded)
        gate.stop()
    }

    @MainActor
    func testBriefGoodThenDarkDoesNotAverageOut() {
        // Many good readings must not dilute one dark one — a median or
        // mean would pass this room; the worst-reading rule must not.
        let gate = LightingGateController()
        gate.activate()
        for t in 0..<20 { gate.ingest(lumens: 800, at: TimeInterval(t)) }
        gate.ingest(lumens: 100, at: 20)
        gate.finishSurvey()
        XCTAssertEqual(gate.status, .complete(worst: .dark))
        XCTAssertFalse(gate.status.allowsStart)
        gate.stop()
    }

    @MainActor
    func testGoodThroughoutSummary() {
        let gate = LightingGateController()
        gate.activate()
        gate.ingest(lumens: 700, at: 0)
        gate.ingest(lumens: 620, at: 1)
        gate.finishSurvey()
        XCTAssertEqual(gate.status, .complete(worst: .good))
        XCTAssertTrue(gate.status.allowsStart)
        XCTAssertEqual(gate.status.message, LightingGateCopy.lightGoodThroughout)
        gate.stop()
    }

    @MainActor
    func testDimWorstWarnsButAllowsStart() {
        let gate = LightingGateController()
        gate.activate()
        gate.ingest(lumens: 800, at: 0)
        gate.ingest(lumens: 350, at: 1) // dim spot
        gate.finishSurvey()
        XCTAssertEqual(gate.status, .complete(worst: .dim))
        XCTAssertTrue(gate.status.allowsStart) // warn, don't hold
        XCTAssertEqual(gate.status.message, LightingGateCopy.moreLightNeeded)
        gate.stop()
    }

    // MARK: - Done Checking gating

    @MainActor
    func testDoneCheckingDisabledUntilFirstSample() {
        let gate = LightingGateController()
        XCTAssertFalse(gate.status.canFinish) // idle
        gate.activate()
        XCTAssertEqual(gate.status, .checking)
        XCTAssertFalse(gate.status.canFinish) // nothing measured yet
        XCTAssertFalse(gate.status.allowsStart) // Start held too
        gate.finishSurvey() // tapping early must be a no-op
        XCTAssertEqual(gate.status, .checking)
        gate.ingest(lumens: 640, at: 0)
        XCTAssertTrue(gate.status.canFinish) // one sample is enough
        gate.stop()
    }

    @MainActor
    func testStartHeldDuringWalkUntilDone() {
        // Even in perfect light, Start waits for the estimator to finish
        // the walk — the summary is the gate, not the live band.
        let gate = LightingGateController()
        gate.activate()
        gate.ingest(lumens: 900, at: 0)
        XCTAssertEqual(gate.status, .surveying(worst: .good))
        XCTAssertFalse(gate.status.allowsStart)
        gate.finishSurvey()
        XCTAssertTrue(gate.status.allowsStart)
        gate.stop()
    }

    @MainActor
    func testLateFramesDoNotReopenACompletedSummary() {
        // The session stays alive after Done (so re-check is instant);
        // its frames must not mutate the verdict.
        let gate = LightingGateController()
        gate.activate()
        gate.ingest(lumens: 900, at: 0)
        gate.finishSurvey()
        XCTAssertEqual(gate.status, .complete(worst: .good))
        gate.ingest(lumens: 50, at: 1) // late dark frame after Done
        XCTAssertEqual(gate.status, .complete(worst: .good)) // unchanged
        XCTAssertEqual(gate.worstLumens, 900)
        gate.stop()
    }

    // MARK: - re-check after adding light

    @MainActor
    func testCheckAgainClearsTheDarkVerdict() {
        let gate = LightingGateController()
        gate.activate()
        gate.ingest(lumens: 80, at: 0)
        gate.finishSurvey()
        XCTAssertFalse(gate.status.allowsStart)
        gate.checkAgain() // painter added the work light
        XCTAssertEqual(gate.status, .checking)
        XCTAssertNil(gate.worstLumens) // fresh walk, old corner cleared
        gate.ingest(lumens: 750, at: 10)
        gate.finishSurvey()
        XCTAssertEqual(gate.status, .complete(worst: .good))
        XCTAssertTrue(gate.status.allowsStart)
        gate.stop()
    }

    // MARK: - frame intake (the delegate's path into ingest)

    @MainActor
    func testFrameIntakeThrottlesTo5Hz() {
        // 60 fps in, ~5 samples/s ingested — every frame processed used to
        // flood the main run loop until ARKit stopped camera delivery.
        let gate = LightingGateController()
        gate.activate()
        for i in 0..<60 { // one second of frames at 60 fps
            gate.receive(lumens: 800, at: TimeInterval(i) / 60.0)
        }
        XCTAssertEqual(gate.status, .surveying(worst: .good))
        XCTAssertLessThanOrEqual(gate.sampleCount, 6) // ≈5 Hz from 60 fps
        XCTAssertGreaterThanOrEqual(gate.sampleCount, 4)
        gate.stop()
    }

    @MainActor
    func testFramesWithoutEstimateDoNotResolveTheGate() {
        // Frames arriving with a nil light estimate must not count as
        // samples — the gate stays checking (and the timeout reason will
        // say frames arrived, distinguishing this from a dead camera).
        let gate = LightingGateController()
        gate.activate()
        gate.receive(lumens: nil, at: 0)
        gate.receive(lumens: nil, at: 0.1)
        XCTAssertEqual(gate.status, .checking)
        gate.warmupTimedOut()
        guard case .unavailable(let reason) = gate.status else {
            return XCTFail("expected .unavailable, got \(gate.status)")
        }
        XCTAssertTrue(reason.contains("2 frames"), "reason should carry frame diagnostics: \(reason)")
        gate.stop()
    }

    @MainActor
    func testWorstReadingSurvivesThrottling() {
        // A dark frame inside a throttle window must still... it can be
        // dropped — but a dark STRETCH (anything ≥ the sample interval,
        // i.e. any real dark corner a human walks past) always lands.
        let gate = LightingGateController()
        gate.activate()
        gate.receive(lumens: 900, at: 0)
        for i in 0..<30 { // half a second standing in the dark corner
            gate.receive(lumens: 60, at: 0.3 + TimeInterval(i) / 60.0)
        }
        XCTAssertEqual(gate.status, .surveying(worst: .dark))
        gate.stop()
    }

    // MARK: - fail-open paths (unchanged behaviour)

    @MainActor
    func testWarmupTimeoutFailsOpenVisibly() {
        // A session that never produces a sample (camera denied, silently
        // dead) must neither hold Start hostage nor vanish without trace.
        let gate = LightingGateController()
        gate.activate()
        XCTAssertFalse(gate.status.allowsStart)
        gate.warmupTimedOut()
        guard case .unavailable = gate.status else {
            return XCTFail("expected .unavailable, got \(gate.status)")
        }
        XCTAssertTrue(gate.status.allowsStart) // fail open
        XCTAssertNil(gate.status.message) // silent in release; DEBUG readout says why
        gate.stop()
    }

    @MainActor
    func testTimeoutDuringLiveSurveyIsIgnored() {
        // The warm-up task races the first frame; once samples flow a
        // late-firing timeout must not overwrite the walk.
        let gate = LightingGateController()
        gate.activate()
        gate.ingest(lumens: 120, at: 0)
        XCTAssertEqual(gate.status, .surveying(worst: .dark))
        gate.warmupTimedOut()
        XCTAssertEqual(gate.status, .surveying(worst: .dark)) // unchanged
        gate.stop()
    }

    @MainActor
    func testSessionFailureFailsOpenEvenFromDark() {
        let gate = LightingGateController()
        gate.activate()
        gate.ingest(lumens: 50, at: 0)
        XCTAssertFalse(gate.status.allowsStart)
        gate.handleSessionFailure(reason: "camera unavailable")
        XCTAssertEqual(gate.status, .unavailable(reason: "camera unavailable"))
        XCTAssertNil(gate.worstLumens)
        XCTAssertTrue(gate.status.allowsStart)
        gate.stop()
    }

    @MainActor
    func testLateFrameDoesNotUndoFailOpenVerdict() {
        // A stale in-flight frame arriving after a session failure (or
        // warm-up timeout) must not resurrect the survey — that would
        // re-hold Start on the word of a session already declared dead.
        let gate = LightingGateController()
        gate.activate()
        gate.handleSessionFailure(reason: "camera unavailable")
        XCTAssertTrue(gate.status.allowsStart)
        gate.ingest(lumens: 50, at: 1) // stale dark frame after failure
        XCTAssertEqual(gate.status, .unavailable(reason: "camera unavailable"))
        XCTAssertTrue(gate.status.allowsStart) // fail-open holds
        XCTAssertNil(gate.worstLumens)
        gate.stop()
    }

    @MainActor
    func testInFlightSampleAfterStopIsDiscarded() {
        // A frame hopping actor context can land after stop(); it must not
        // resurrect the gate's state during the RoomPlan handoff.
        let gate = LightingGateController()
        gate.activate()
        gate.ingest(lumens: 800, at: 0)
        gate.finishSurvey()
        gate.stop()
        XCTAssertEqual(gate.status, .idle)
        gate.ingest(lumens: 50, at: 1) // stale in-flight dark frame
        XCTAssertEqual(gate.status, .idle) // unchanged — teardown is final
        XCTAssertTrue(gate.status.allowsStart)
    }

    // MARK: - rolling median window (retained for tuning-campaign logging)

    func testMedianOverOddAndEvenCounts() {
        var window = LightSampleWindow(windowSeconds: 10)
        window.append(lumens: 100, at: 0)
        window.append(lumens: 900, at: 1)
        window.append(lumens: 300, at: 2)
        XCTAssertEqual(window.medianLumens, 300) // odd: middle value
        window.append(lumens: 500, at: 3)
        XCTAssertEqual(window.medianLumens, 400) // even: mean of middle two
    }

    func testOldSamplesFallOutOfTheWindow() {
        var window = LightSampleWindow(windowSeconds: 2.5)
        for t in 0..<5 { window.append(lumens: 50, at: TimeInterval(t)) }
        XCTAssertEqual(window.band, .dark)
        for t in 5..<10 { window.append(lumens: 800, at: TimeInterval(t)) }
        XCTAssertEqual(window.band, .good) // only recent samples remain
        XCTAssertTrue(window.samples.allSatisfy { $0.lumens == 800 })
    }

    func testEmptyWindowIsUnknown() {
        let window = LightSampleWindow()
        XCTAssertNil(window.medianLumens)
        XCTAssertEqual(window.band, .unknown)
    }
}
