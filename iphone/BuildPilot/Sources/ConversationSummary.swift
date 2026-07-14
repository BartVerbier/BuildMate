import Foundation

/// Turns the structured extraction into one natural sentence, e.g.:
/// "From our conversation today I understand you would like the walls
///  painted sage green, while keeping the ceiling as it is."
/// Deterministic templating — no AI involved.
enum ConversationSummary {
    /// Estimator voice: "We will repair the cracks above the window,
    /// prepare the surfaces and paint the walls sage green, while leaving
    /// the ceiling as it is."
    static func sentence(for requirements: RequirementExtraction) -> String {
        var actions: [String] = []
        if !requirements.preparationRequired.isEmpty {
            actions.append(naturalList(requirements.preparationRequired.map(lowercasedLead)))
        }
        actions.append("prepare the surfaces")
        if !requirements.scopeOfWork.isEmpty {
            actions.append(naturalList(requirements.scopeOfWork.map(lowercasedLead)))
        } else {
            actions.append("freshly paint the room")
        }

        var sentence = "We will " + naturalList(actions)
        if !requirements.exclusions.isEmpty {
            sentence += ", while leaving " + naturalList(requirements.exclusions.map(lowercasedLead)) + " as it is"
        }
        return sentence + "."
    }

    /// The remaining details worth listing under the sentence.
    static func details(for requirements: RequirementExtraction) -> [String] {
        requirements.specialNotes
    }

    private static func naturalList(_ items: [String]) -> String {
        guard let last = items.last else { return "" }
        switch items.count {
        case 1: return last
        case 2: return "\(items[0]) and \(last)"
        default: return items.dropLast().joined(separator: ", ") + " and \(last)"
        }
    }

    private static func lowercasedLead(_ text: String) -> String {
        // "Paint the walls sage green" → "the walls painted sage green" is
        // over-clever; just soften the leading capital so items read inline.
        guard let first = text.first else { return text }
        return first.lowercased() + text.dropFirst()
    }
}
