import SwiftUI

/// The currencies the painter can quote in. Small, curated list — V1 targets a
/// solo European contractor, not every ISO code. `symbol` is for compact inline
/// labels; the full formatted figures come from `Format.money`.
enum CurrencyCatalog {
    static let options: [(code: String, name: String, symbol: String)] = [
        ("EUR", "Euro", "€"),
        ("DKK", "Danish krone", "kr"),
        ("SEK", "Swedish krona", "kr"),
        ("NOK", "Norwegian krone", "kr"),
        ("GBP", "British pound", "£"),
        ("USD", "US dollar", "$"),
        ("PLN", "Polish złoty", "zł"),
        ("CHF", "Swiss franc", "Fr"),
    ]

    static func symbol(_ code: String) -> String {
        options.first { $0.code == code }?.symbol ?? code
    }

    static func name(_ code: String) -> String {
        options.first { $0.code == code }?.name ?? code
    }
}

/// A money amount entered in the contractor's own currency. Blank stays blank
/// while editing; a non-negative value is enforced on the binding.
struct MoneyField: View {
    let title: String
    let currencyCode: String
    @Binding var amount: Double
    var footnote: String? = nil

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let footnote {
                    Text(footnote).font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer()
            TextField("0", value: Binding(
                get: { amount },
                set: { amount = max(0, $0) }
            ), format: .number.precision(.fractionLength(0 ... 2)))
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: 110)
            Text(CurrencyCatalog.symbol(currencyCode))
                .foregroundStyle(.secondary)
        }
    }
}

/// Edits a percentage that is STORED as a fraction (0.20 ⇄ 20 %). Clamped to a
/// sensible range on commit so discount/markup can't be pushed into nonsense.
struct PercentField: View {
    let title: String
    @Binding var fraction: Double
    var maxPercent: Double = 100
    var footnote: String? = nil

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let footnote {
                    Text(footnote).font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer()
            TextField("0", value: Binding(
                get: { fraction * 100 },
                set: { fraction = min(max(0, $0), maxPercent) / 100 }
            ), format: .number.precision(.fractionLength(0 ... 1)))
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: 70)
            Text("%").foregroundStyle(.secondary)
        }
    }
}

/// A plain positive decimal (coverage m²/L, etc). `minimum` guards the values
/// that divide — coverage must never be zero.
struct DecimalField: View {
    let title: String
    @Binding var value: Double
    var unit: String
    var minimum: Double = 0
    var footnote: String? = nil

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let footnote {
                    Text(footnote).font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer()
            TextField("0", value: Binding(
                get: { value },
                set: { value = max(minimum, $0) }
            ), format: .number.precision(.fractionLength(0 ... 1)))
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: 80)
            Text(unit).foregroundStyle(.secondary)
        }
    }
}
