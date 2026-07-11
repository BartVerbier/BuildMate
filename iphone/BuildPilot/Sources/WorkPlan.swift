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

    static func stages(
        for requirements: RequirementExtraction,
        measurements: RoomMeasurement? = nil
    ) -> [Stage] {
        var result: [Stage] = [
            Stage(id: "prep", title: "Preparation", items: preparationItems(measurements)),
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
            "Return furniture to its place",
            "Clean and tidy the work area",
        ]))
        return result
    }

    /// Preparation the customer can picture: what gets moved, what is
    /// protected in place, what stays untouched — from the scan's own
    /// fixed/movable object counts when available.
    private static func preparationItems(_ measurements: RoomMeasurement?) -> [String] {
        var items: [String] = []
        let movable = measurements?.movableObjects ?? 0
        let fixed = measurements?.fixedObjects ?? 0
        if movable > 0 {
            items.append(movable == 1
                ? "Move 1 furniture item to the centre and cover it with dust sheets"
                : "Move \(movable) furniture items to the centre and cover them with dust sheets")
        } else {
            items.append("Move and cover any furniture with dust sheets")
        }
        if fixed > 0 {
            items.append(fixed == 1
                ? "Protect 1 built-in unit in place — it is not moved"
                : "Protect \(fixed) built-in units in place — they are not moved")
        }
        items.append("Cover and protect the floors")
        items.append("Take down pictures, curtains and wall fixtures")
        items.append("Mask edges, sockets and switches")
        return items
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
