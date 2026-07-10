import Foundation

/// A completed visit kept on the device so the painter can reopen recent
/// estimates. Presentation-layer persistence only — the Mac's session
/// directories remain the source of truth.
struct VisitRecord: Codable, Identifiable {
    let id: String // backend session_id
    let name: String
    let date: Date
    let session: SessionResponse
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

    func add(name: String, session: SessionResponse) {
        let record = VisitRecord(id: session.sessionId, name: name, date: Date(), session: session)
        records.removeAll { $0.id == record.id }
        records.insert(record, at: 0)
        records = Array(records.prefix(Self.maxRecords))
        save()
    }

    func delete(at offsets: IndexSet) {
        records.remove(atOffsets: offsets)
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
