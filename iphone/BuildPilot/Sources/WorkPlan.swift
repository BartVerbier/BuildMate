import Foundation

/// Deterministic estimator-voice content generated from the extraction:
/// staged scope of work, optional recommendations, and project duration.
/// No AI — same inputs, same words, every time.
enum WorkPlan {
    struct Stage: Identifiable {
        let id: String
        let title: String
        let items: [String]
    }

    static func stages(for requirements: RequirementExtraction) -> [Stage] {
        var result: [Stage] = [
            Stage(id: "prep", title: "Preparation", items: [
                "Protect furniture and floors",
                "Mask edges, sockets and switches",
            ]),
        ]
        if !requirements.preparationRequired.isEmpty {
            result.append(Stage(
                id: "repairs", title: "Repairs",
                items: requirements.preparationRequired + ["Sand and level repairs"]
            ))
        }
        var painting = ["Prime surfaces where needed"]
        painting += requirements.scopeOfWork
        painting.append("Apply two finish coats")
        result.append(Stage(id: "paint", title: "Painting", items: painting))
        result.append(Stage(id: "done", title: "Completion", items: [
            "Remove protection and masking",
            "Clean and tidy the work area",
        ]))
        return result
    }

    /// Rule-based optional extras — recommendations only, never priced in.
    static func recommendations(for requirements: RequirementExtraction) -> [String] {
        var suggestions: [String] = []
        let allText = (requirements.scopeOfWork + requirements.exclusions
                       + requirements.specialNotes).joined(separator: " ").lowercased()
        if !requirements.paintScope.ceiling {
            suggestions.append("Paint the ceiling while the room is prepared")
        }
        if !allText.contains("wood") && !allText.contains("trim") && !allText.contains("skirting") {
            suggestions.append("Refresh woodwork and skirting boards")
        }
        if requirements.preparationRequired.isEmpty {
            suggestions.append("Inspect and repair plaster before painting")
        }
        return Array(suggestions.prefix(3))
    }

    struct Duration {
        let preparation: String
        let painting: String
        let drying: String
        let total: String
    }

    /// Duration derived from the estimate's labour hours (7.5h work days;
    /// coats dry overnight). Advisory, like everything else in the quote.
    static func duration(labourHours: Double) -> Duration {
        let days = max(1, Int((labourHours / 7.5).rounded(.up)))
        return Duration(
            preparation: "First morning",
            painting: days == 1 ? "1 working day" : "\(days) working days",
            drying: "Overnight between coats",
            total: days == 1 ? "≈ 1–2 days" : "≈ \(days)–\(days + 1) days"
        )
    }
}
