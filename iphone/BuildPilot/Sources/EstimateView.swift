import SwiftUI

/// Draft estimate review. The price is the hero; everything below it exists
/// to build confidence in that number. Used in the visit flow (onDone set)
/// and when reopening a recent visit (onDone nil, plain navigation).
struct EstimateView: View {
    let session: SessionResponse
    let visitName: String
    let onDone: (() -> Void)?

    @State private var quoteURL: URL?

    var body: some View {
        content
            .navigationTitle("Draft Estimate")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if onDone != nil {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { onDone?() }
                    }
                }
            }
            .safeAreaInset(edge: .bottom) { shareBar }
            .task { renderQuote() }
            .modifier(WrapInStackIfNeeded(needsStack: onDone != nil))
    }

    private var content: some View {
        ScrollView {
            VStack(spacing: 16) {
                heroCard
                breakdownCard
                if let m = session.measurements { measurementsCard(m) }
                if let r = session.requirements { requirementsCards(r) }
                if let e = session.estimate { assumptionsCard(e) }
                advisoryFooter
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 12)
        }
        .background(Color(.systemGroupedBackground))
    }

    // MARK: sections

    private var heroCard: some View {
        VStack(spacing: 6) {
            Text(visitName)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text(Format.euroRounded(session.estimate?.suggestedQuotationEur ?? 0))
                .font(.system(size: 56, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.green)
                .minimumScaleFactor(0.5)
                .lineLimit(1)
            Text("Suggested price · incl. VAT")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private var breakdownCard: some View {
        Card(title: "Breakdown") {
            if let e = session.estimate {
                LabeledRow("Labour", detail: Format.hours(e.labourHours), value: Format.euro(e.labourCostEur))
                LabeledRow("Materials", value: Format.euro(e.materialCostEur))
                LabeledRow("Paint", value: Format.litres(e.paintQuantityLitres))
                LabeledRow("Primer", value: Format.litres(e.primerQuantityLitres))
            }
        }
    }

    private func measurementsCard(_ m: RoomMeasurement) -> some View {
        Card(title: "Room") {
            LabeledRow("Walls (net)", value: Format.squareMetres(m.netWallAreaM2))
            LabeledRow("Ceiling", value: Format.squareMetres(m.ceilingAreaM2))
            LabeledRow("Floor", value: Format.squareMetres(m.floorAreaM2))
            LabeledRow("Scan confidence", value: "\(Int((m.confidenceScore * 100).rounded())) %")
        }
    }

    @ViewBuilder
    private func requirementsCards(_ r: RequirementExtraction) -> some View {
        if !r.scopeOfWork.isEmpty {
            Card(title: "Scope of Work") { BulletList(items: r.scopeOfWork) }
        }
        if !r.exclusions.isEmpty {
            Card(title: "Not Included") { BulletList(items: r.exclusions) }
        }
        if !r.preparationRequired.isEmpty {
            Card(title: "Preparation") { BulletList(items: r.preparationRequired) }
        }
        if !r.specialNotes.isEmpty {
            Card(title: "Customer Notes") { BulletList(items: r.specialNotes) }
        }
    }

    private func assumptionsCard(_ e: EstimateDraft) -> some View {
        Card(title: nil) {
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 8) {
                    // Customer-safe trail: quantities and coverage only.
                    // Internal pricing (margin) stays on developer surfaces —
                    // the Mac console and the session record.
                    ForEach(customerSafeAssumptions(e), id: \.self) { line in
                        Text(line)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Text("The total includes labour, materials, travel and VAT.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.top, 8)
            } label: {
                Label("How this was calculated", systemImage: "function")
                    .font(.body.weight(.medium))
            }
        }
    }

    /// Filters the deterministic trail to what the homeowner may see:
    /// drops the pricing composition line (which itemizes internal margin).
    private func customerSafeAssumptions(_ e: EstimateDraft) -> [String] {
        e.assumptions.filter { !$0.hasPrefix("Quotation:") && !$0.lowercased().contains("margin") }
    }

    private var advisoryFooter: some View {
        Text("This is a draft. Review every number before quoting the customer.")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(.top, 4)
    }

    private var shareBar: some View {
        Group {
            if let quoteURL {
                ShareLink(item: quoteURL, preview: SharePreview(visitName)) {
                    shareLabel
                }
            } else {
                // PDF rendering failed — share a plain-text quote instead,
                // so the painter is never blocked.
                ShareLink(item: quoteText) {
                    shareLabel
                }
            }
        }
        .buttonStyle(.borderedProminent)
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 4)
        .background(.bar)
    }

    private var shareLabel: some View {
        Label("Share Quote", systemImage: "square.and.arrow.up")
            .font(.title3.weight(.semibold))
            .frame(maxWidth: .infinity, minHeight: 56)
    }

    private var quoteText: String {
        let identity = BusinessIdentity.load()
        var lines: [String] = []
        if !identity.companyName.isEmpty { lines.append(identity.companyName) }
        if !identity.contactLine.isEmpty { lines.append(identity.contactLine) }
        lines.append("Painting Estimate — \(visitName)")
        if let e = session.estimate {
            lines.append("Suggested price (incl. VAT): \(Format.euro(e.suggestedQuotationEur))")
            lines.append("Labour: \(Format.hours(e.labourHours)) · \(Format.euro(e.labourCostEur))")
            lines.append("Materials: \(Format.euro(e.materialCostEur))")
            lines.append("Paint: \(Format.litres(e.paintQuantityLitres)) · Primer: \(Format.litres(e.primerQuantityLitres))")
        }
        if let r = session.requirements, !r.scopeOfWork.isEmpty {
            lines.append("Scope: " + r.scopeOfWork.joined(separator: "; "))
        }
        lines.append("Draft estimate — subject to final review.")
        return lines.joined(separator: "\n")
    }

    private func renderQuote() {
        quoteURL = QuotePDF.render(
            session: session,
            visitName: visitName,
            identity: BusinessIdentity.load()
        )
    }
}

// MARK: - building blocks

private struct Card<Content: View>: View {
    let title: String?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title {
                Text(title.uppercased())
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .kerning(0.6)
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

private struct LabeledRow: View {
    let label: String
    let detail: String?
    let value: String

    init(_ label: String, detail: String? = nil, value: String) {
        self.label = label
        self.detail = detail
        self.value = value
    }

    var body: some View {
        HStack {
            Text(label)
            if let detail {
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(value)
                .font(.body.weight(.medium).monospacedDigit())
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

private struct BulletList: View {
    let items: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(items, id: \.self) { item in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Circle()
                        .fill(.tertiary)
                        .frame(width: 5, height: 5)
                        .offset(y: -2)
                    Text(item)
                }
            }
        }
    }
}

/// The visit flow presents EstimateView inside a fullScreenCover (no stack);
/// history pushes it onto the existing stack. Wrap only when needed.
private struct WrapInStackIfNeeded: ViewModifier {
    let needsStack: Bool

    func body(content: Content) -> some View {
        if needsStack {
            NavigationStack { content }
        } else {
            content
        }
    }
}
