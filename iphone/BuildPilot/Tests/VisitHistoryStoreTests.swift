@testable import BuildPilot
import XCTest

/// Focused tests for the Edit Plan / reopened-editing state that lives in
/// VisitHistoryStore: in-place update, no duplicate, confirmation → modified,
/// stale flags, and reopen persistence.
@MainActor
final class VisitHistoryStoreTests: XCTestCase {
    private func makeStore(_ url: URL? = nil) -> VisitHistoryStore {
        VisitHistoryStore(
            fileURL: url ?? FileManager.default.temporaryDirectory
                .appendingPathComponent("hist-\(UUID().uuidString).json")
        )
    }

    private func session(_ id: String) -> SessionResponse {
        SessionResponse(
            sessionId: id, status: "completed", measurements: nil, requirements: nil,
            estimate: nil, companyProfile: nil, confidence: nil, rawMetadata: nil
        )
    }

    func testEditInPlaceDoesNotDuplicateAndPreservesCustomer() {
        let store = makeStore()
        store.add(name: "Kitchen", session: session("v1"))
        store.setCustomer(name: "Alice", address: "1 Road", for: "v1")
        // Re-saving the same session_id is an in-place edit, never a new visit.
        store.add(name: "Kitchen", session: session("v1"))
        XCTAssertEqual(store.records.count, 1)
        XCTAssertEqual(store.record(for: "v1")?.customerName, "Alice")
    }

    func testConfirmThenEditMovesToModified() {
        let store = makeStore()
        store.add(name: "Kitchen", session: session("v1"))
        store.setPlanState("confirmed", for: "v1")
        XCTAssertEqual(store.record(for: "v1")?.planState, "confirmed")
        store.markStale(pdf: true, visualization: false, for: "v1")
        XCTAssertEqual(store.record(for: "v1")?.planState, "modified")
    }

    func testStaleFlagsAreIndependentAndClearable() {
        let store = makeStore()
        store.add(name: "Kitchen", session: session("v1"))
        // Notes-only style edit: PDF stale, visualization NOT.
        store.markStale(pdf: true, visualization: false, for: "v1")
        XCTAssertEqual(store.record(for: "v1")?.pdfStale, true)
        XCTAssertNotEqual(store.record(for: "v1")?.visualizationStale, true)
        // Surface change: visualization stale too.
        store.markStale(pdf: true, visualization: true, for: "v1")
        XCTAssertEqual(store.record(for: "v1")?.visualizationStale, true)
        // Regenerating clears it.
        store.clearStale(pdf: true, for: "v1")
        XCTAssertEqual(store.record(for: "v1")?.pdfStale, false)
    }

    func testEditPreservesStateAndStaleAcrossReSave() {
        let store = makeStore()
        store.add(name: "Kitchen", session: session("v1"))
        store.setPlanState("confirmed", for: "v1")
        store.markStale(pdf: true, visualization: true, for: "v1") // now "modified"
        store.add(name: "Kitchen", session: session("v1"))          // another in-place edit
        XCTAssertEqual(store.records.count, 1)
        XCTAssertEqual(store.record(for: "v1")?.planState, "modified")
        XCTAssertEqual(store.record(for: "v1")?.pdfStale, true)
    }

    func testReopenLoadsSameRecordWithState() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("hist-\(UUID().uuidString).json")
        let store = makeStore(url)
        store.add(name: "Kitchen", session: session("v1"))
        store.setPlanState("confirmed", for: "v1")
        // A fresh store on the same file = reopening the same visit.
        let reopened = makeStore(url)
        XCTAssertEqual(reopened.records.count, 1)
        XCTAssertEqual(reopened.record(for: "v1")?.planState, "confirmed")
    }

    // MARK: - reopened-visit voice editing ("Make Changes")

    private func snapshot() -> BusinessSnapshot {
        BusinessSnapshot(
            companyName: "Nordic", contactName: "Ari", phone: "", email: "",
            website: "", address: "", vatNumber: "", currencyCode: "DKK", terms: "T"
        )
    }

    /// A reopened voice edit applies the /revise result to the SAME record in
    /// place — no duplicate, session replaced, customer/photos/snapshot/state
    /// all preserved, and outputs marked stale (PDF always; visualization only
    /// when the backend requires a re-render). Mirrors the exact store calls in
    /// VisitController.applyHistoricalRevision.
    func testHistoricalRevisionUpdatesInPlacePreservingEverything() {
        let store = makeStore()
        store.add(name: "Kitchen", session: session("v1"), business: snapshot())
        store.setCustomer(name: "Alice", address: "1 Road", for: "v1")
        store.addPhoto(VisitPhoto(id: "p1", kind: .before, fileName: "p1.jpg", date: Date()), to: "v1")
        store.setPlanState("confirmed", for: "v1")

        // The revision: same id, new session content, render required → viz stale.
        store.add(name: "Kitchen", session: session("v1"))
        store.markStale(pdf: true, visualization: true, for: "v1")

        XCTAssertEqual(store.records.count, 1)                     // no duplicate visit
        let r = store.record(for: "v1")
        XCTAssertEqual(r?.customerName, "Alice")                   // customer preserved
        XCTAssertEqual(r?.photos?.count, 1)                        // photos preserved
        XCTAssertEqual(r?.businessSnapshot?.currencyCode, "DKK")   // snapshot preserved
        XCTAssertEqual(r?.planState, "modified")                  // confirmed → modified
        XCTAssertEqual(r?.pdfStale, true)                          // PDF stale
        XCTAssertEqual(r?.visualizationStale, true)                // render required → viz stale
    }

    func testRevisionMetadataCountsInPlaceEditsOnly() {
        let store = makeStore()
        store.add(name: "Kitchen", session: session("v1"))       // first creation
        XCTAssertNil(store.record(for: "v1")?.revisionCount)      // not a revision
        XCTAssertNil(store.record(for: "v1")?.lastRevisedAt)

        store.add(name: "Kitchen", session: session("v1"))       // in-place edit #1
        XCTAssertEqual(store.record(for: "v1")?.revisionCount, 1)
        XCTAssertNotNil(store.record(for: "v1")?.lastRevisedAt)

        store.add(name: "Kitchen", session: session("v1"))       // in-place edit #2
        XCTAssertEqual(store.record(for: "v1")?.revisionCount, 2)

        // A different, freshly-created visit carries no revision metadata.
        store.add(name: "Hall", session: session("v2"))
        XCTAssertNil(store.record(for: "v2")?.revisionCount)
    }

    func testHistoricalRevisionWithoutRenderKeepsVisualizationFresh() {
        let store = makeStore()
        store.add(name: "Kitchen", session: session("v1"))
        // renderRequired = false → PDF stale, visualization left untouched.
        store.add(name: "Kitchen", session: session("v1"))
        store.markStale(pdf: true, visualization: false, for: "v1")
        XCTAssertEqual(store.records.count, 1)
        XCTAssertEqual(store.record(for: "v1")?.pdfStale, true)
        XCTAssertNotEqual(store.record(for: "v1")?.visualizationStale, true)
    }
}
