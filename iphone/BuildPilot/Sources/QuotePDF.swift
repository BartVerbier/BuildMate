import SwiftUI

/// Renders the draft quote as a PDF for the native share sheet
/// (Mail, Messages, WhatsApp, AirDrop, Print, Save to Files).
@MainActor
enum QuotePDF {
    static func render(session: SessionResponse, visitName: String) -> URL? {
        let pageWidth: CGFloat = 595 // A4 @ 72 dpi
        let renderer = ImageRenderer(
            content: QuoteDocumentView(session: session, visitName: visitName)
                .frame(width: pageWidth)
        )
        renderer.proposedSize = ProposedViewSize(width: pageWidth, height: nil)

        let fileName = "Quote — \(visitName.replacingOccurrences(of: "/", with: "-")).pdf"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)

        var rendered = false
        renderer.render { size, draw in
            let pageHeight = max(size.height, 842)
            var box = CGRect(x: 0, y: 0, width: pageWidth, height: pageHeight)
            guard let context = CGContext(url as CFURL, mediaBox: &box, nil) else { return }
            context.beginPDFPage(nil)
            // SwiftUI draws top-down; PDF space is bottom-up — align to the top.
            context.translateBy(x: 0, y: pageHeight - size.height)
            draw(context)
            context.endPDFPage()
            context.closePDF()
            rendered = true
        }
        return rendered ? url : nil
    }
}

/// The printable quote — a light, paper-like document (independent of the
/// app's dark appearance).
struct QuoteDocumentView: View {
    let session: SessionResponse
    let visitName: String

    private var estimate: EstimateDraft? { session.estimate }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Painting Estimate")
                        .font(.system(size: 26, weight: .bold))
                    Text(visitName)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(Date.now, format: .dateTime.day().month(.wide).year())
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .padding(.bottom, 18)

            divider

            if let e = estimate {
                // Price
                HStack(alignment: .firstTextBaseline) {
                    Text("Suggested quotation")
                        .font(.system(size: 14, weight: .medium))
                    Spacer()
                    Text(Format.euro(e.suggestedQuotationEur))
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                }
                .padding(.vertical, 14)
                Text("Includes labour, materials, travel, margin, and VAT.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 16)

                divider

                section("Breakdown") {
                    line("Labour (\(Format.hours(e.labourHours)))", Format.euro(e.labourCostEur))
                    line("Materials", Format.euro(e.materialCostEur))
                    line("Paint required", Format.litres(e.paintQuantityLitres))
                    line("Primer required", Format.litres(e.primerQuantityLitres))
                }
            }

            if let m = session.measurements {
                section("Room Measurements") {
                    line("Walls (net of doors and windows)", Format.squareMetres(m.netWallAreaM2))
                    line("Ceiling", Format.squareMetres(m.ceilingAreaM2))
                    line("Floor", Format.squareMetres(m.floorAreaM2))
                }
            }

            if let r = session.requirements {
                if !r.scopeOfWork.isEmpty { bulletSection("Scope of Work", r.scopeOfWork) }
                if !r.exclusions.isEmpty { bulletSection("Not Included", r.exclusions) }
                if !r.preparationRequired.isEmpty { bulletSection("Preparation", r.preparationRequired) }
                if !r.specialNotes.isEmpty { bulletSection("Notes", r.specialNotes) }
            }

            Spacer(minLength: 24)
            divider
            Text("Draft estimate — advisory and subject to final review by your painter.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .padding(.top, 10)
        }
        .padding(44)
        .frame(minHeight: 842, alignment: .top)
        .background(.white)
        .foregroundStyle(.black)
        .environment(\.colorScheme, .light)
    }

    private var divider: some View {
        Rectangle().fill(Color.black.opacity(0.12)).frame(height: 1)
    }

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .kerning(0.8)
                .padding(.top, 16)
            content()
        }
        .padding(.bottom, 6)
    }

    private func bulletSection(_ title: String, _ items: [String]) -> some View {
        section(title) {
            ForEach(items, id: \.self) { item in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("•")
                    Text(item)
                }
                .font(.system(size: 12))
            }
        }
    }

    private func line(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(.system(size: 12))
            Spacer()
            Text(value).font(.system(size: 12, weight: .semibold))
        }
        .padding(.vertical, 1)
    }
}
