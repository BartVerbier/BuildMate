@testable import BuildPilot
import XCTest

/// The reopened-visit voice edit must tell the painter WHAT went wrong, not a
/// single generic message. This pins the mapping at the narrowest confirmed
/// failure seam: the on-device bug was a backend 404 (session no longer on the
/// server) being shown as "couldn't update the quote."
///
/// This exercises the error-surfacing logic only — it makes NO claim about
/// microphone capture or the network, which aren't unit-testable here.
final class HistoricalRevisionOutcomeTests: XCTestCase {
    func testSuccessHasNoFailureMessage() {
        XCTAssertNil(HistoricalRevisionOutcome.success(["Total +€100"]).failureMessage)
    }

    /// The exact regression: a 404 must read as "no longer on the server",
    /// distinct from the generic failure.
    func testVisitNotFoundIsSpecificAndDistinct() {
        let message = HistoricalRevisionOutcome.visitNotFound.failureMessage
        XCTAssertNotNil(message)
        XCTAssertTrue(message!.localizedCaseInsensitiveContains("no longer on the server"))
        XCTAssertNotEqual(HistoricalRevisionOutcome.visitNotFound.failureMessage,
                          HistoricalRevisionOutcome.failed.failureMessage)
    }

    func testEachFailureHasItsOwnReason() {
        XCTAssertTrue(HistoricalRevisionOutcome.recordingUnavailable.failureMessage!
            .localizedCaseInsensitiveContains("audio"))
        XCTAssertTrue(HistoricalRevisionOutcome.serverUnreachable.failureMessage!
            .localizedCaseInsensitiveContains("reached"))
        XCTAssertTrue(HistoricalRevisionOutcome.couldNotTranscribe.failureMessage!
            .localizedCaseInsensitiveContains("understood"))
        // All non-success reasons are distinct — no two failures read the same.
        let messages = [
            HistoricalRevisionOutcome.recordingUnavailable,
            .serverUnreachable, .visitNotFound, .couldNotTranscribe, .failed,
        ].map(\.failureMessage)
        XCTAssertEqual(Set(messages).count, messages.count)
    }
}
