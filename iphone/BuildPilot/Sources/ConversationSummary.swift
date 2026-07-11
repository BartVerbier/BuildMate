import Foundation

/// Turns the structured extraction into one natural sentence, e.g.:
/// "From our conversation today I understand you would like the walls
///  painted sage green, while keeping the ceiling as it is."
/// Deterministic templating — no AI involved.
enum ConversationSummary {
    static func sentence(for requirements: RequirementExtraction) -> String {
        var clauses: [String] = []

        if !requirements.scopeOfWork.isEmpty {
            clauses.append("you would like " + naturalList(requirements.scopeOfWork.map(lowercasedLead)))
        }
        if !requirements.exclusions.isEmpty {
            clauses.append("keeping " + naturalList(requirements.exclusions.map(lowercasedLead)) + " as it is")
        }
        if !requirements.preparationRequired.isEmpty {
            clauses.append("we'll also take care of " + naturalList(requirements.preparationRequired.map(lowercasedLead)))
        }

        guard !clauses.isEmpty else {
            return "From our conversation today I understand you'd like this room freshly painted."
        }
        var sentence = "From our conversation today I understand " + clauses[0]
        if clauses.count > 1 {
            sentence += ", while " + clauses[1]
        }
        sentence += "."
        if clauses.count > 2 {
            sentence += " " + clauses[2].prefix(1).uppercased() + clauses[2].dropFirst() + "."
        }
        return sentence
    }

    /// The remaining details worth listing under the sentence.
    static func details(for requirements: RequirementExtraction) -> [String] {
        requirements.specialNotes
    }

    private static func naturalList(_ items: [String]) -> String {
        switch items.count {
        case 0: return ""
        case 1: return items[0]
        case 2: return "\(items[0]) and \(items[1])"
        default: return items.dropLast().joined(separator: ", ") + " and \(items.last!)"
        }
    }

    private static func lowercasedLead(_ text: String) -> String {
        // "Paint the walls sage green" → "the walls painted sage green" is
        // over-clever; just soften the leading capital so items read inline.
        guard let first = text.first else { return text }
        return first.lowercased() + text.dropFirst()
    }
}
