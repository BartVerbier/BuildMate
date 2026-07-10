import SwiftUI
import UIKit

/// Renders the customer quotation as a paginated A4 PDF:
///   Page 1  — letterhead (logo, company), customer, date, price, breakdown
///   Page 2  — measurements, scope, notes, calculation basis, terms
///   Then    — "Existing Condition" (before photos), 4 per page
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
        // Presentation order: cover → Current Room → Proposed Result →
        // Scope of Work → Price Breakdown (→ Completed Result, post-job).
        let photos = record?.photos ?? []
        let visitID = session.sessionId
        var pages: [AnyView] = [
            AnyView(SummaryPage(session: session, visitName: visitName, identity: identity, record: record))
        ]
        pages += photoPages(title: "Current Room",
                            photos: photos.filter { $0.kind == .before }, visitID: visitID)
        pages += photoPages(title: "Proposed Result",
                            photos: photos.filter { $0.kind == .visualization }, visitID: visitID,
                            caption: "AI visualization generated from a photo of this room, showing only the requested finishes. Final result may vary slightly.")
        pages.append(AnyView(DetailPage(session: session, identity: identity)))
        pages.append(AnyView(PricePage(session: session, identity: identity)))
        pages += photoPages(title: "Completed Result",
                            photos: photos.filter { $0.kind == .after }, visitID: visitID)

        let fileName = "Quote — \(visitName.replacingOccurrences(of: "/", with: "-")).pdf"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)

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
                }
                .padding(.bottom, 8)
            }

            if let e = estimate {
                // Price block
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Total (incl. VAT)")
                            .font(.system(size: 14, weight: .medium))
                        Spacer()
                        Text(Format.euro(e.suggestedQuotationEur))
                            .font(.system(size: 32, weight: .bold, design: .rounded))
                    }
                    if let vat = vatLine(e) {
                        HStack {
                            Spacer()
                            Text(vat).font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.vertical, 14)
                Divide()
                Text("The following pages show your room today, the proposed result, the full scope of work, and the price breakdown.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.top, 12)
            }

            Spacer(minLength: 0)
            Divide()
            Text("Draft quotation — advisory and subject to final confirmation.")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
                .padding(.top, 8)
        }
    }

    private func vatLine(_ e: EstimateDraft) -> String? {
        guard let rate = session.companyProfile?.vatRate, rate > 0 else { return nil }
        let vatAmount = e.suggestedQuotationEur - e.suggestedQuotationEur / (1 + rate)
        return "of which VAT (\(Int((rate * 100).rounded())) %): \(Format.euro(vatAmount))"
    }
}

// MARK: - page 2: details

private struct DetailPage: View {
    let session: SessionResponse
    let identity: BusinessIdentity

    var body: some View {
        PageChrome {
            Text("Scope of Work")
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
                if !r.scopeOfWork.isEmpty { bullets("Scope of Work", r.scopeOfWork) }
                if !r.exclusions.isEmpty { bullets("Not Included", r.exclusions) }
                if !r.preparationRequired.isEmpty { bullets("Preparation", r.preparationRequired) }
                if !r.specialNotes.isEmpty { bullets("Customer Notes", r.specialNotes) }
            }

            if let e = session.estimate {
                SectionTitle("Calculation Basis")
                ForEach(customerSafeAssumptions(e), id: \.self) { line in
                    Text("•  \(line)")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 1)
                }
            }

            Spacer(minLength: 0)
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

// MARK: - price breakdown page

private struct PricePage: View {
    let session: SessionResponse
    let identity: BusinessIdentity

    var body: some View {
        PageChrome {
            Text("Price Breakdown")
                .font(.system(size: 18, weight: .bold))
                .padding(.bottom, 6)
            Divide()

            if let e = session.estimate {
                SectionTitle("Breakdown")
                Line("Labour (\(Format.hours(e.labourHours)))", Format.euro(e.labourCostEur))
                Line("Materials", Format.euro(e.materialCostEur))
                Line("Paint required", Format.litres(e.paintQuantityLitres))
                Line("Primer required", Format.litres(e.primerQuantityLitres))
                Text("The total also covers travel and overheads.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)

                SectionTitle("Total")
                if let rate = session.companyProfile?.vatRate, rate > 0 {
                    let vat = e.suggestedQuotationEur - e.suggestedQuotationEur / (1 + rate)
                    Line("VAT (\(Int((rate * 100).rounded())) %)", Format.euro(vat))
                }
                HStack {
                    Text("Total (incl. VAT)").font(.system(size: 14, weight: .semibold))
                    Spacer()
                    Text(Format.euro(e.suggestedQuotationEur))
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                }
                .padding(.vertical, 6)
            }

            Spacer(minLength: 12)

            SectionTitle("Terms & Conditions")
            Text(identity.terms)
                .font(.system(size: 9.5))
                .foregroundStyle(.secondary)
                .lineLimit(10)
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
