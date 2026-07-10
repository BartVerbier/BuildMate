import SwiftUI

/// The draft estimate review screen. Everything shown here is advisory —
/// the painter has final approval.
struct EstimateView: View {
    let session: SessionResponse
    let onDone: () -> Void

    var body: some View {
        NavigationStack {
            List {
                if let estimate = session.estimate {
                    Section("Draft quotation") {
                        HStack {
                            Text("Suggested total (incl. VAT)")
                            Spacer()
                            Text(euro(estimate.suggestedQuotationEur))
                                .font(.title3.bold())
                        }
                        row("Materials", euro(estimate.materialCostEur))
                        row("Labour", euro(estimate.labourCostEur))
                        row("Labour hours", String(format: "%.2f h", estimate.labourHours))
                        row("Paint", String(format: "%.1f L", estimate.paintQuantityLitres))
                        row("Primer", String(format: "%.1f L", estimate.primerQuantityLitres))
                    }
                }

                if let m = session.measurements {
                    Section("Measurements") {
                        row("Net wall area", sqm(m.netWallAreaM2))
                        row("Ceiling area", sqm(m.ceilingAreaM2))
                        row("Floor area", sqm(m.floorAreaM2))
                        row("Doors / windows", sqm(m.doorAreaM2 + m.windowAreaM2))
                        row("Scan confidence", String(format: "%.0f %%", m.confidenceScore * 100))
                    }
                }

                if let r = session.requirements {
                    if !r.scopeOfWork.isEmpty {
                        Section("Scope of work") {
                            ForEach(r.scopeOfWork, id: \.self) { Text($0) }
                        }
                    }
                    if !r.exclusions.isEmpty {
                        Section("Exclusions") {
                            ForEach(r.exclusions, id: \.self) { Text($0) }
                        }
                    }
                    if !r.preparationRequired.isEmpty {
                        Section("Preparation") {
                            ForEach(r.preparationRequired, id: \.self) { Text($0) }
                        }
                    }
                    if !r.specialNotes.isEmpty {
                        Section("Notes") {
                            ForEach(r.specialNotes, id: \.self) { Text($0) }
                        }
                    }
                }

                if let estimate = session.estimate {
                    Section("How this was calculated") {
                        ForEach(estimate.assumptions, id: \.self) {
                            Text($0).font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }

                Section {
                    Text("This estimate is advisory. Review every number before quoting the customer.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Draft Estimate")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("New Visit", action: onDone)
                }
            }
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value).foregroundStyle(.secondary)
        }
    }

    private func euro(_ value: Double) -> String {
        "€" + String(format: "%.2f", value)
    }

    private func sqm(_ value: Double) -> String {
        String(format: "%.1f m²", value)
    }
}
