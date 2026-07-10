import Foundation

/// Display formatting only — all values arrive computed from the backend.
enum Format {
    private static let euroFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = "EUR"
        f.currencySymbol = "€"
        f.maximumFractionDigits = 0 // hero prices read better without cents
        return f
    }()

    private static let euroExactFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = "EUR"
        f.currencySymbol = "€"
        f.minimumFractionDigits = 2
        f.maximumFractionDigits = 2
        return f
    }()

    static func euroRounded(_ value: Double) -> String {
        euroFormatter.string(from: value as NSNumber) ?? "€\(Int(value))"
    }

    static func euro(_ value: Double) -> String {
        euroExactFormatter.string(from: value as NSNumber) ?? String(format: "€%.2f", value)
    }

    static func litres(_ value: Double) -> String {
        String(format: "%.1f L", value)
    }

    static func hours(_ value: Double) -> String {
        String(format: "%.2f h", value)
    }

    static func squareMetres(_ value: Double) -> String {
        String(format: "%.1f m²", value)
    }

    static func elapsed(since start: Date, now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(start)))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}
