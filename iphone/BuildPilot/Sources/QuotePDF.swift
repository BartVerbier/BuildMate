import SwiftUI
import UIKit

/// Renders the customer quotation as a paginated A4 PDF:
///   Page 1  — executive summary: letterhead, customer, the whole quotation
///             at a glance (areas, paint, labour, materials, VAT, total)
///   Page 2  — "Your Room": today → prepared & protected → finished result
///   Page 3  — scope of work, duration, exclusions, pricing, terms
///   Then    — "Completed Result" (after photos), only if any exist
@MainActor
enum QuotePDF {
    static let pageWidth: CGFloat = 595 // A4 @ 72 dpi
    static let pageHeight: CGFloat = 842

    static func render(
        session: SessionResponse,
        visitName: String,
        identity: BusinessIdentity,
        record: VisitRecord?
    ) -> URL? {
        // Premium quotation: Page 1 executive summary → Page 2 the
        // transformation (current room + AI preview) → Page 3 scope,
        // materials, preparation and pricing (→ Completed Result post-job).
        let photos = record?.photos ?? []
        let visitID = session.sessionId
        var pages: [AnyView] = [
            AnyView(SummaryPage(session: session, visitName: visitName, identity: identity, record: record))
        ]
        let bestBefore = photos.first { $0.kind == .before }
            .flatMap { PhotoStore.load($0, visitID: visitID) }
        let preparation = photos.last { $0.kind == .preparation }
            .flatMap { PhotoStore.load($0, visitID: visitID) }
        let preview = photos.last { $0.kind == .visualization }
            .flatMap { PhotoStore.load($0, visitID: visitID) }
        if bestBefore != nil || preview != nil {
            pages.append(AnyView(TransformPage(
                before: bestBefore, preparation: preparation, preview: preview
            )))
        }
        pages.append(AnyView(DetailPage(session: session, identity: identity)))
        pages += photoPages(title: "Completed Result",
                            photos: photos.filter { $0.kind == .after }, visitID: visitID)

        let fileName = "Quote — \(visitName.replacingOccurrences(of: "/", with: "-")).pdf"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)

        let beforeCount = photos.filter { $0.kind == .before }.count
        let vizCount = photos.filter { $0.kind == .visualization }.count
        visitLog.info("Quote PDF: \(pages.count) pages — before photos: \(beforeCount), visualizations: \(vizCount), after: \(photos.filter { $0.kind == .after }.count)")

        var mediaBox = CGRect(x: 0, y: 0, width: pageWidth, height: pageHeight)
        guard let context = CGContext(url as CFURL, mediaBox: &mediaBox, nil) else { return nil }
        for page in pages {
            let renderer = ImageRenderer(
                content: page.frame(width: pageWidth, height: pageHeight)
            )
            renderer.proposedSize = ProposedViewSize(width: pageWidth, height: pageHeight)
            renderer.render { _, draw in
                context.beginPDFPage(nil)
                draw(context)
                context.endPDFPage()
            }
        }
        context.closePDF()
        return url
    }

    private static func photoPages(
        title: String, photos: [VisitPhoto], visitID: String, caption: String? = nil
    ) -> [AnyView] {
        guard !photos.isEmpty else { return [] }
        return stride(from: 0, to: photos.count, by: 4).map { start in
            AnyView(PhotoPage(
                title: title,
                photos: Array(photos[start ..< min(start + 4, photos.count)]),
                visitID: visitID,
                continued: start > 0,
                caption: start == 0 ? caption : nil
            ))
        }
    }
}

// MARK: - shared page styling

private struct PageChrome<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .padding(44)
            .frame(width: QuotePDF.pageWidth, height: QuotePDF.pageHeight, alignment: .top)
            .background(.white)
            .foregroundStyle(.black)
            .environment(\.colorScheme, .light)
    }
}

private struct Divide: View {
    var body: some View {
        Rectangle().fill(Color.black.opacity(0.12)).frame(height: 1)
    }
}

private struct SectionTitle: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
            .kerning(0.8)
            .padding(.top, 14)
            .padding(.bottom, 4)
    }
}

private struct Line: View {
    let label: String
    let value: String

    init(_ label: String, _ value: String) {
        self.label = label
        self.value = value
    }

    var body: some View {
        HStack {
            Text(label).font(.system(size: 12))
            Spacer()
            Text(value).font(.system(size: 12, weight: .semibold))
        }
        .padding(.vertical, 1.5)
    }
}

// MARK: - page 1: letterhead + summary

private struct SummaryPage: View {
    let session: SessionResponse
    let visitName: String
    let identity: BusinessIdentity
    let record: VisitRecord?

    private var estimate: EstimateDraft? { session.estimate }
    private func money(_ v: Double, rounded: Bool = false) -> String {
        Format.money(v, currency: session.currencyCode, rounded: rounded)
    }

    /// Deterministic quote number derived from the visit id
    /// (visit-YYYYMMDD-HHMMSS-hex → Q-YYYYMMDD-HEX).
    private var quoteNumber: String {
        let parts = session.sessionId.split(separator: "-")
        guard parts.count >= 4 else { return "Q-\(session.sessionId.suffix(6).uppercased())" }
        return "Q-\(parts[1])-\(parts[3].uppercased())"
    }

    var body: some View {
        PageChrome {
            // Letterhead
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    if !identity.companyName.isEmpty {
                        Text(identity.companyName)
                            .font(.system(size: 20, weight: .bold))
                    }
                    if !identity.contactLine.isEmpty {
                        Text(identity.contactLine)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                    if !identity.address.isEmpty {
                        Text(identity.address)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                    let idLine = [identity.website, identity.vatNumber.isEmpty ? "" : "VAT \(identity.vatNumber)"]
                        .filter { !$0.isEmpty }.joined(separator: " · ")
                    if !idLine.isEmpty {
                        Text(idLine)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if let logo = identity.logo {
                    Image(uiImage: logo)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: 120, maxHeight: 56, alignment: .topTrailing)
                }
            }
            .padding(.bottom, 18)
            Divide()

            // Title / customer / date
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Painting Quotation")
                        .font(.system(size: 26, weight: .bold))
                        .padding(.top, 14)
                    Text(visitName)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 3) {
                    Text(quoteNumber)
                        .font(.system(size: 12, weight: .bold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color(red: 1.0, green: 0.78, blue: 0.05).opacity(0.25))
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                    Text(Date.now, format: .dateTime.day().month(.wide).year())
                    Text(Date.now, format: .dateTime.hour().minute())
                        .foregroundStyle(.secondary)
                }
                .font(.system(size: 11))
                .padding(.top, 18)
            }
            .padding(.bottom, 10)

            if let name = record?.customerName, !name.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    SectionTitle("Prepared for")
                    Text(name).font(.system(size: 13, weight: .semibold))
                    if let address = record?.customerAddress, !address.isEmpty {
                        Text(address).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    let contact = [record?.customerPhone, record?.customerEmail]
                        .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
                    if !contact.isEmpty {
                        Text(contact).font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }
                .padding(.bottom, 8)
            }

            if let e = estimate {
                // Executive summary: the whole quotation at a glance —
                // areas, quantities, cost lines, then the total.
                SectionTitle("Your Quotation at a Glance")
                // A specific-wall request that couldn't be grounded means
                // every number below prices the WHOLE room — the PDF must
                // say so as loudly as the app does, or the quote reads as
                // correctly scoped when it isn't.
                if let warning = WallScopeAlert.message(for: session.requirements) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("⚠").font(.system(size: 12, weight: .bold))
                        Text(warning)
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundStyle(.orange)
                    .padding(8)
                    .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
                    .padding(.bottom, 6)
                }
                if let m = session.measurements {
                    if let sel = session.wallSelection {
                        Line("Paintable wall area (\(sel.selected) of \(sel.total) walls)",
                             Format.squareMetres(sel.areaM2))
                    } else {
                        Line("Paintable wall area", Format.squareMetres(m.netWallAreaM2))
                    }
                    Line("Ceiling area", ceilingValue(m))
                }
                Line("Estimated paint required", paintValue(e))
                Line("Labour (\(Format.hours(e.labourHours)))", money(e.labourCostEur))
                Line("Materials", money(e.materialCostEur))
                Line("Preparation & protection", preparationValue)
                if let rate = session.companyProfile?.vatRate, rate > 0 {
                    let vat = e.suggestedQuotationEur - e.suggestedQuotationEur / (1 + rate)
                    Line("VAT (\(Int((rate * 100).rounded())) %)", money(vat))
                }
                HStack(alignment: .firstTextBaseline) {
                    Text("TOTAL (incl. VAT)")
                        .font(.system(size: 13, weight: .bold))
                        .kerning(0.4)
                    Spacer()
                    Text(money(e.suggestedQuotationEur))
                        .font(.system(size: 26, weight: .bold, design: .rounded))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(Color(red: 1.0, green: 0.78, blue: 0.05).opacity(0.3))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .padding(.top, 8)

                if let r = session.requirements, r.transcriptAvailable {
                    SectionTitle("Project Summary")
                    Text(ConversationSummary.sentence(for: r))
                        .font(.system(size: 12.5))
                        .lineSpacing(3)
                        .padding(.bottom, 2)
                }
                Text("The following pages show your room today, the proposed result, and the full scope with pricing.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .padding(.top, 12)
            }

            Spacer(minLength: 0)
            Divide()
            HStack {
                Text("Draft quotation — advisory and subject to final confirmation.")
                Spacer()
                Text("Prepared with BuildMate")
            }
            .font(.system(size: 9))
            .foregroundStyle(.secondary)
            .padding(.top, 8)
        }
    }

    private func ceilingValue(_ m: RoomMeasurement) -> String {
        let area = Format.squareMetres(m.ceilingAreaM2)
        if session.requirements?.paintScope.ceiling == false {
            return "\(area) — not painted"
        }
        return area
    }

    private func paintValue(_ e: EstimateDraft) -> String {
        e.primerQuantityLitres > 0
            ? "\(Format.litres(e.paintQuantityLitres)) + \(Format.litres(e.primerQuantityLitres)) primer"
            : Format.litres(e.paintQuantityLitres)
    }

    /// What preparation covers in this room, from the scan's object counts.
    private var preparationValue: String {
        let movable = session.measurements?.movableObjects ?? 0
        let fixed = session.measurements?.fixedObjects ?? 0
        var parts: [String] = []
        if movable > 0 { parts.append("\(movable) item\(movable == 1 ? "" : "s") moved") }
        if fixed > 0 { parts.append("\(fixed) protected in place") }
        return parts.isEmpty ? "Included" : "Included — " + parts.joined(separator: ", ")
    }
}

// MARK: - page 2: details

private struct DetailPage: View {
    let session: SessionResponse
    let identity: BusinessIdentity

    private func money(_ v: Double) -> String {
        Format.money(v, currency: session.currencyCode)
    }

    var body: some View {
        PageChrome {
            Text("Scope of Work & Pricing")
                .font(.system(size: 18, weight: .bold))
                .padding(.bottom, 6)
            Divide()

            if let m = session.measurements {
                SectionTitle("Room Measurements")
                Line("Walls (net of doors and windows)", Format.squareMetres(m.netWallAreaM2))
                Line("Ceiling", Format.squareMetres(m.ceilingAreaM2))
                Line("Floor area", Format.squareMetres(m.floorAreaM2))
                Line("Doors and windows", Format.squareMetres(m.doorAreaM2 + m.windowAreaM2))
            }

            if let r = session.requirements {
                SectionTitle("Scope of Work")
                ForEach(WorkPlan.stages(for: r, measurements: session.measurements)) { stage in
                    Text(stage.title)
                        .font(.system(size: 10.5, weight: .semibold))
                        .padding(.top, 3)
                    ForEach(stage.items.prefix(5), id: \.self) { item in
                        Text("•  \(item)").font(.system(size: 10.5)).padding(.vertical, 0.5)
                    }
                }
                if let e = session.estimate {
                    let duration = WorkPlan.duration(labourHours: e.labourHours)
                    SectionTitle("Project Duration")
                    Line("Painting", duration.painting)
                    Line("Total duration", duration.total)
                }
                SectionTitle("Not Included")
                ForEach(r.exclusions, id: \.self) { item in
                    Text("•  \(item)").font(.system(size: 10.5)).padding(.vertical, 0.5)
                }
                Text("•  As standard: woodwork, trim, glass, stone, radiators and natural wood are left unpainted unless requested.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                let suggestions = WorkPlan.recommendations(for: r)
                if !suggestions.isEmpty {
                    SectionTitle("Worth Considering (optional)")
                    ForEach(suggestions, id: \.self) { item in
                        Text("□  \(item)").font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }
                if !r.specialNotes.isEmpty { bullets("Customer Notes", r.specialNotes) }
            }

            if let e = session.estimate {
                SectionTitle("Pricing")
                Line("Labour (\(Format.hours(e.labourHours)))", money(e.labourCostEur))
                Line("Materials", money(e.materialCostEur))
                Line("Paint required", Format.litres(e.paintQuantityLitres))
                Line("Primer required", Format.litres(e.primerQuantityLitres))
                if let rate = session.companyProfile?.vatRate, rate > 0 {
                    let vat = e.suggestedQuotationEur - e.suggestedQuotationEur / (1 + rate)
                    Line("VAT (\(Int((rate * 100).rounded())) %)", money(vat))
                }
                HStack {
                    Text("Total (incl. VAT)").font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Text(money(e.suggestedQuotationEur))
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                }
                .padding(.vertical, 5)
                Text("The total also covers travel and overheads.")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)

                SectionTitle("Calculation Basis")
                ForEach(customerSafeAssumptions(e).prefix(5), id: \.self) { line in
                    Text("•  \(line)")
                        .font(.system(size: 9.5))
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 1)
                }
            }

            Spacer(minLength: 8)

            SectionTitle("Terms & Conditions")
            Text(identity.terms)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
                .lineLimit(6)
        }
    }

    private func bullets(_ title: String, _ items: [String]) -> some View {
        Group {
            SectionTitle(title)
            ForEach(items.prefix(10), id: \.self) { item in
                Text("•  \(item)").font(.system(size: 12)).padding(.vertical, 1)
            }
        }
    }

    private func customerSafeAssumptions(_ e: EstimateDraft) -> [String] {
        e.assumptions
            .filter { !$0.hasPrefix("Quotation:") && !$0.lowercased().contains("margin") }
            .prefix(8)
            .map { $0 }
    }
}

// MARK: - transformation page

private struct TransformPage: View {
    let before: UIImage?
    let preparation: UIImage?
    let preview: UIImage?

    var body: some View {
        PageChrome {
            Text("Your Room")
                .font(.system(size: 18, weight: .bold))
                .padding(.bottom, 6)
            Divide()

            if let before, let preparation {
                // Three stages: today + prepared side by side, finished hero.
                HStack(alignment: .top, spacing: 17) {
                    labeled("1 · TODAY", image: before, size: CGSize(width: 245, height: 180))
                    labeled("2 · PREPARED & PROTECTED", image: preparation, size: CGSize(width: 245, height: 180))
                }
            } else if let before {
                labeled("CURRENT ROOM", image: before, size: CGSize(width: 507, height: 280))
            }
            if let preview {
                labeled(preparation != nil ? "3 · THE FINISHED RESULT" : "AI PREVIEW — PROPOSED RESULT",
                        image: preview, size: CGSize(width: 507, height: 300))
                Text("AI visualization generated from a photo of this room, showing only the requested finishes. Furniture is moved and protected during the work and returned when finished. Final result may vary slightly.")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
            }
            Spacer(minLength: 0)
        }
    }

    private func labeled(_ title: String, image: UIImage, size: CGSize) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            SectionTitle(title)
            // scaledToFit, never fill: the customer must see the complete
            // photograph — cropping here silently cut walls out of the quote.
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.black.opacity(0.05))
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .padding(2)
            }
            .frame(width: size.width, height: size.height)
        }
    }
}

// MARK: - photo pages

private struct PhotoPage: View {
    let title: String
    let photos: [VisitPhoto]
    let visitID: String
    let continued: Bool
    var caption: String?

    private let cell = CGSize(width: 240, height: 300)

    var body: some View {
        PageChrome {
            Text(continued ? "\(title) (continued)" : title)
                .font(.system(size: 18, weight: .bold))
                .padding(.bottom, 6)
            Divide()
            if let caption {
                Text(caption)
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
                    .padding(.top, 6)
            }

            LazyVGrid(
                columns: [GridItem(.fixed(cell.width), spacing: 16), GridItem(.fixed(cell.width))],
                spacing: 16
            ) {
                ForEach(photos) { photo in
                    VStack(alignment: .leading, spacing: 4) {
                        if let image = PhotoStore.load(photo, visitID: visitID) {
                            Image(uiImage: image)
                                .resizable()
                                .scaledToFill()
                                .frame(width: cell.width, height: cell.height)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                        } else {
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Color.black.opacity(0.06))
                                .frame(width: cell.width, height: cell.height)
                        }
                        Text(photo.date, format: .dateTime.day().month().year())
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.top, 16)

            Spacer(minLength: 0)
        }
    }
}
