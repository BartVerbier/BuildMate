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
}
