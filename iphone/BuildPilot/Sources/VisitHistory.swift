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
}

@MainActor
final class VisitHistoryStore: ObservableObject {
    @Published private(set) var records: [VisitRecord] = []

    private static let maxRecords = 20
    private let fileURL: URL

    init() {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        fileURL = documents.appendingPathComponent("visit-history.json")
        load()
    }

    func add(name: String, session: SessionResponse, customer: CustomerInfo? = nil) {
        var record = VisitRecord(id: session.sessionId, name: name, date: Date(), session: session)
        if let customer {
            record.customerName = customer.name.isEmpty ? nil : customer.name
            record.customerAddress = customer.address.isEmpty ? nil : customer.address
            record.customerPhone = customer.phone.isEmpty ? nil : customer.phone
            record.customerEmail = customer.email.isEmpty ? nil : customer.email
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
