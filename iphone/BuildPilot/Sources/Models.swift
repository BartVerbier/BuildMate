import Foundation

// Codable mirror of the backend session contract (the subset the app displays).
// Field names match backend/buildpilot/models/session.py — snake_case keys
// are mapped via the decoder's keyDecodingStrategy.

struct SessionResponse: Codable {
    let sessionId: String
    let status: String
    let measurements: RoomMeasurement?
    let requirements: RequirementExtraction?
    let estimate: EstimateDraft?
    let companyProfile: CompanyProfileInfo? // optional: absent in older stored visits
    let confidence: ConfidenceReport? // optional: absent in visits from earlier versions
    let rawMetadata: [String: String]?
}

/// How much to trust the scan's measurements (0–100), with an explainable
/// breakdown. Computed deterministically on the backend (never AI). The app
/// renders `band`, `signals`, and `tips` generically, so new backend signals
/// appear here with no client change.
struct ConfidenceReport: Codable {
    let score: Int
    let band: String // "high" | "medium" | "low"
    let headline: String
    let signals: [ConfidenceSignal]
    let tips: [String]
}

struct ConfidenceSignal: Codable, Identifiable {
    var id: String { key }
    let key: String
    let label: String
    let score: Double // 0–1, 1 = best
    let weight: Double
    let detail: String
    let tip: String?
}

/// /health response — used to verify which backend the phone is talking to.
struct ServerInfo: Codable {
    struct Version: Codable {
        let commit: String
        let source: String
    }
    let version: Version?
    let visualizerAvailable: Bool?
    let authentication: String?
}

/// The slice of the company profile the app displays (VAT line on the quote)
/// and lets the painter edit (coats).
struct CompanyProfileInfo: Codable {
    let vatRate: Double
    let currency: String
    let coats: Int? // optional: absent in visits stored before Edit Plan
}

/// Result of a customer revision: the updated session plus what changed.
/// `renderRequired` — the old visualization no longer matches the quote and
/// the phone should re-request the AI renders (POST /visualize).
struct RevisionResponse: Codable {
    let session: SessionResponse
    let changes: [String]
    let version: Int
    let renderRequired: Bool
}

struct RoomMeasurement: Codable {
    let grossWallAreaM2: Double
    let netWallAreaM2: Double
    let ceilingAreaM2: Double
    let floorAreaM2: Double
    let doorAreaM2: Double
    let windowAreaM2: Double
    let paintableSurfaceAreaM2: Double
    let confidenceScore: Double
    // Optional: absent in visits stored by earlier versions.
    let fixedObjects: Int?
    let movableObjects: Int?
    let walls: [WallDetail]?
    let notes: [String]
    // True when a human verified/corrected the measurements on site. Recorded
    // separately from confidenceScore, which stays the original scan value.
    let measurementsVerified: Bool?
}

/// Structured manual edits sent to POST /sessions/{id}/reestimate. Only changed
/// fields are populated; snake_case keys are produced by the encoder.
struct PlanEditPayload: Encodable {
    struct WallEditPayload: Encodable {
        let wallId: String
        var widthM: Double?
        var heightM: Double?
        var openingAreaM2: Double?
    }
    var walls: [WallEditPayload]?
    var ceilingAreaM2: Double?
    var doorAreaM2: Double?
    var windowAreaM2: Double?
    var paintScope: PaintScope?
    var paintedWallIds: [String]?
    var coats: Int?
    var scopeOfWork: [String]?
    var exclusions: [String]?
    var preparationRequired: [String]?
    var specialNotes: [String]?
    var measurementsVerified: Bool = false
}

/// One reconstructed wall, individually measurable ("w1", "w2", ...).
struct WallDetail: Codable {
    let wallId: String
    let widthM: Double
    let heightM: Double
    let grossAreaM2: Double
    let openingAreaM2: Double
    let netAreaM2: Double
}

struct PaintScope: Codable {
    let walls: Bool
    let ceiling: Bool
}

struct RequirementExtraction: Codable {
    let scopeOfWork: [String]
    let exclusions: [String]
    let preparationRequired: [String]
    let specialNotes: [String]
    let paintScope: PaintScope
    // Walls being painted, by wall id; empty/absent = all walls.
    let paintedWallIds: [String]?
    // The customer's own words for a wall the backend could NOT map to a
    // wall id (post-scan revisions have no gaze context). When set and
    // paintedWallIds is empty, the quote covers ALL walls despite a
    // specific-wall request — surfaced loudly until walls are chosen.
    var unresolvedWallReference: String? = nil
    let transcriptAvailable: Bool
}

/// The whole-room-fallback warning: active when a specific-wall request
/// could not be grounded and the quote therefore covers ALL walls. Clears
/// itself the moment painted walls are actually chosen (Edit Plan).
enum WallScopeAlert {
    static func reference(for requirements: RequirementExtraction?) -> String? {
        guard let requirements,
              let reference = requirements.unresolvedWallReference,
              (requirements.paintedWallIds ?? []).isEmpty
        else { return nil }
        return reference
    }

    /// TBD/PLACEHOLDER COPY — needs a copy pass.
    static func message(for requirements: RequirementExtraction?) -> String? {
        reference(for: requirements).map {
            "Couldn't match “\($0)” to a specific wall — this quote covers the WHOLE ROOM."
        }
    }
}

extension SessionResponse {
    /// The currency this visit was priced in — snapshotted on the session, so
    /// every figure (app + PDF) reads in it and a historical quote keeps its
    /// own currency. Falls back to EUR for visits stored before currency choice.
    var currencyCode: String {
        estimate?.currency ?? companyProfile?.currency ?? "EUR"
    }

    /// The wall selection when the conversation limited painting to
    /// specific walls: (selected count, total walls, painted area in m²).
    /// Nil when the whole room's walls are in scope.
    var wallSelection: (selected: Int, total: Int, areaM2: Double)? {
        guard let ids = requirements?.paintedWallIds, !ids.isEmpty,
              let walls = measurements?.walls, !walls.isEmpty else { return nil }
        let selected = walls.filter { ids.contains($0.wallId) }
        guard !selected.isEmpty else { return nil }
        return (selected.count, walls.count, selected.reduce(0) { $0 + $1.netAreaM2 })
    }
}

struct EstimateDraft: Codable {
    let paintQuantityLitres: Double
    let primerQuantityLitres: Double
    let labourHours: Double
    let materialCostEur: Double
    let labourCostEur: Double
    let suggestedQuotationEur: Double
    let currency: String
    let assumptions: [String]
}
