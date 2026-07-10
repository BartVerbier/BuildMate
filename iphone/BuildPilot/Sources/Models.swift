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
    let rawMetadata: [String: String]?
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
    let notes: [String]
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
    let transcriptAvailable: Bool
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
