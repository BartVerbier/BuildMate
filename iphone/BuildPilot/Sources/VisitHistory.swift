import Foundation

/// A completed visit kept on the device so the painter can reopen recent
/// estimates. Presentation-layer persistence only — the Mac's session
/// directories remain the source of truth.
struct VisitRecord: Codable, Identifiable {
    let id: String // backend session_id
    var name: String
    let date: Date
    let session: SessionResponse
    // Added for the customer deliverable; optional so records saved by
    // earlier builds still decode.
    var photos: [VisitPhoto]?
    var customerName: String?
    var customerAddress: String?
    var customerPhone: String?
    var customerEmail: String?
    // Workflow state (Edit Plan). nil = draft/unconfirmed. Optional so records
    // saved by earlier builds still decode.
    var planState: String?              // "confirmed" | "modified"
    var pdfStale: Bool?                 // a shared/generated PDF no longer matches
    var visualizationStale: Bool?       // renders no longer match the plan
    // The business identity frozen at creation. The visit's PDF renders from
    // this, so editing global settings later never rewrites an old quote.
    // Optional so records saved by earlier builds still decode (they fall back
    // to the live identity, matching prior behaviour).
    var businessSnapshot: BusinessSnapshot?
}

@MainActor
final class VisitHistoryStore: ObservableObject {
    @Published private(set) var records: [VisitRecord] = []

    private static let maxRecords = 20
    private let fileURL: URL

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("visit-history.json")
        load()
    }

    func add(name: String, session: SessionResponse, customer: CustomerInfo? = nil,
             business: BusinessSnapshot? = nil) {
        // Updating an existing visit (e.g. a customer revision) must never
        // lose what's already attached to it — photos and contact details
        // carry over; only the session content is replaced.
        let existing = records.first { $0.id == session.sessionId }
        var record = VisitRecord(
            id: session.sessionId, name: name,
            date: existing?.date ?? Date(), session: session
        )
        record.photos = existing?.photos
        record.customerName = existing?.customerName
        record.customerAddress = existing?.customerAddress
        record.customerPhone = existing?.customerPhone
        record.customerEmail = existing?.customerEmail
        record.planState = existing?.planState
        record.pdfStale = existing?.pdfStale
        record.visualizationStale = existing?.visualizationStale
        // Freeze the business identity once, at creation; every later in-place
        // edit keeps the original snapshot so the quote never silently restyles.
        record.businessSnapshot = existing?.businessSnapshot ?? business
        if let customer {
            record.customerName = customer.name.isEmpty ? record.customerName : customer.name
            record.customerAddress = customer.address.isEmpty ? record.customerAddress : customer.address
            record.customerPhone = customer.phone.isEmpty ? record.customerPhone : customer.phone
            record.customerEmail = customer.email.isEmpty ? record.customerEmail : customer.email
        }
        records.removeAll { $0.id == record.id }
        records.insert(record, at: 0)
        records = Array(records.prefix(Self.maxRecords))
        save()
    }

    func delete(at offsets: IndexSet) {
        records.remove(atOffsets: offsets)
        save()
    }

    /// Removes a visit by id — used when a rescan replaces the current visit's
    /// estimate in place rather than leaving a duplicate entry.
    func remove(id: String) {
        records.removeAll { $0.id == id }
        save()
    }

    func record(for visitID: String) -> VisitRecord? {
        records.first { $0.id == visitID }
    }

    func addPhoto(_ photo: VisitPhoto, to visitID: String) {
        guard let index = records.firstIndex(where: { $0.id == visitID }) else { return }
        records[index].photos = (records[index].photos ?? []) + [photo]
        save()
    }

    func setCustomer(name: String, address: String, for visitID: String) {
        guard let index = records.firstIndex(where: { $0.id == visitID }) else { return }
        records[index].customerName = name.isEmpty ? nil : name
        records[index].customerAddress = address.isEmpty ? nil : address
        save()
    }

    func setPlanState(_ state: String, for visitID: String) {
        guard let index = records.firstIndex(where: { $0.id == visitID }) else { return }
        records[index].planState = state
        save()
    }

    /// After a saved edit: flag stale outputs and, if the plan was confirmed,
    /// move it to "modified". `pdf`/`visualization` are set independently so a
    /// notes-only edit can mark the PDF without invalidating renders.
    func markStale(pdf: Bool, visualization: Bool, for visitID: String) {
        guard let index = records.firstIndex(where: { $0.id == visitID }) else { return }
        if pdf { records[index].pdfStale = true }
        if visualization { records[index].visualizationStale = true }
        if records[index].planState == "confirmed" {
            records[index].planState = "modified"
        }
        save()
    }

    func clearStale(pdf: Bool = false, visualization: Bool = false, for visitID: String) {
        guard let index = records.firstIndex(where: { $0.id == visitID }) else { return }
        if pdf { records[index].pdfStale = false }
        if visualization { records[index].visualizationStale = false }
        save()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([VisitRecord].self, from: data)
        else { return }
        records = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(records) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
