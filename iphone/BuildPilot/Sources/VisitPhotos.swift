import Foundation
import UIKit

/// Photo documentation for a visit: existing condition (before), optional
/// progress shots, and the completed result (after). Photos live in the
/// app's Documents (never lost with the app installed) and are archived to
/// the backend session directory as the permanent project record.
enum PhotoKind: String, Codable, CaseIterable, Identifiable {
    case before, progress, after
    case visualization // AI "proposed result" render — never captured by camera

    var id: String { rawValue }

    /// Kinds the painter can capture manually.
    static var cameraKinds: [PhotoKind] { [.before, .progress, .after] }

    var label: String {
        switch self {
        case .before: return "Before"
        case .progress: return "Progress"
        case .after: return "After"
        case .visualization: return "Proposed"
        }
    }
}

struct VisitPhoto: Codable, Identifiable, Equatable {
    let id: String
    let kind: PhotoKind
    let fileName: String
    let date: Date
}

/// Saves and loads visit photos on disk: Documents/photos/<visitId>/<uuid>.jpg
enum PhotoStore {
    static func directory(for visitID: String) -> URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return documents.appendingPathComponent("photos").appendingPathComponent(visitID)
    }

    @discardableResult
    static func save(_ image: UIImage, visitID: String, kind: PhotoKind) -> VisitPhoto? {
        guard let data = image.jpegData(compressionQuality: 0.85) else { return nil }
        let dir = directory(for: visitID)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let photo = VisitPhoto(
            id: UUID().uuidString,
            kind: kind,
            fileName: "\(UUID().uuidString).jpg",
            date: Date()
        )
        do {
            try data.write(to: dir.appendingPathComponent(photo.fileName), options: .atomic)
            return photo
        } catch {
            visitLog.error("Photo save failed: \(error.localizedDescription)")
            return nil
        }
    }

    static func load(_ photo: VisitPhoto, visitID: String) -> UIImage? {
        UIImage(contentsOfFile: directory(for: visitID).appendingPathComponent(photo.fileName).path)
    }

    static func jpegData(_ photo: VisitPhoto, visitID: String) -> Data? {
        try? Data(contentsOf: directory(for: visitID).appendingPathComponent(photo.fileName))
    }
}
