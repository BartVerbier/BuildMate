import SwiftUI

/// Draft estimate review. The price is the hero; everything below it exists
/// to build confidence in that number. Used in the visit flow (onDone set)
/// and when reopening a recent visit (onDone nil, plain navigation).
struct EstimateView: View {
    let session: SessionResponse
    let visitName: String
    @ObservedObject var history: VisitHistoryStore
    var visualizationPending: Bool = false
    let onDone: (() -> Void)?

    @State private var quoteURL: URL?
    @State private var takingPhotoKind: PhotoKind?
    @State private var editingCustomer = false
    @State private var viewerSelection: ViewerSelection?

    struct ViewerSelection: Identifiable {
        let id = UUID()
        let index: Int
    }
    @AppStorage("backendURL") private var backendURLString = ""

    private var record: VisitRecord? { history.record(for: session.sessionId) }
    private var allPhotos: [VisitPhoto] { record?.photos ?? [] }
    /// Camera photos only — the AI visualization has its own card.
    private var photos: [VisitPhoto] { allPhotos.filter { $0.kind != .visualization } }
    private var visualization: VisitPhoto? { allPhotos.last { $0.kind == .visualization } }
    /// Live visit: existing condition. Reopened later: completed result.
    private var defaultPhotoKind: PhotoKind { onDone != nil ? .before : .after }

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
                proposedResultCard
                customerCard
                photosCard
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
        .sheet(item: $takingPhotoKind) { kind in
            CameraPicker { image in addPhoto(image, kind: kind) }
                .ignoresSafeArea()
        }
        .fullScreenCover(item: $viewerSelection) { selection in
            PhotoViewer(photos: allPhotos, visitID: session.sessionId, index: selection.index)
        }
        .sheet(isPresented: $editingCustomer, onDismiss: renderQuote) {
            CustomerDetailsSheet(
                name: record?.customerName ?? "",
                address: record?.customerAddress ?? ""
            ) { name, address in
                history.setCustomer(name: name, address: address, for: session.sessionId)
            }
        }
    }

    // MARK: proposed result

    private var bestBefore: VisitPhoto? { allPhotos.first { $0.kind == .before } }

    @ViewBuilder
    private var proposedResultCard: some View {
        if let visualization, let vizImage = PhotoStore.load(visualization, visitID: session.sessionId) {
            Card(title: "The Transformation") {
                if let before = bestBefore,
                   let beforeImage = PhotoStore.load(before, visitID: session.sessionId) {
                    transformationImage(beforeImage, label: "TODAY", photo: before)
                    Image(systemName: "arrow.down")
                        .font(.title3.weight(.bold))
                        .foregroundStyle(.yellow)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 2)
                }
                transformationImage(vizImage, label: "PROPOSED", photo: visualization)
                Text("AI visualization based on your room — final result may vary slightly.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .onAppear { renderQuote() } // ensure the PDF includes it
        } else if visualizationPending {
            Card(title: "Proposed Result") {
                HStack(spacing: 12) {
                    ProgressView()
                    Text("Creating a visualization of the finished room…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 44)
            }
        }
    }

    private func transformationImage(_ image: UIImage, label: String, photo: VisitPhoto) -> some View {
        Button {
            if let index = allPhotos.firstIndex(where: { $0.id == photo.id }) {
                viewerSelection = ViewerSelection(index: index)
            }
        } label: {
            ZStack(alignment: .topLeading) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                Text(label)
                    .font(.caption2.weight(.bold))
                    .kerning(0.8)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(label == "PROPOSED" ? Color.yellow : Color.black.opacity(0.55))
                    .foregroundStyle(label == "PROPOSED" ? .black : .white)
                    .clipShape(Capsule())
                    .padding(8)
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: customer & photos

    private var customerCard: some View {
        Card(title: "Customer") {
            Button {
                editingCustomer = true
            } label: {
                HStack {
                    if let name = record?.customerName, !name.isEmpty {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(name).foregroundStyle(.primary)
                            if let address = record?.customerAddress, !address.isEmpty {
                                Text(address).font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                    } else {
                        Text("Add customer details for the quote")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.footnote)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    private var photosCard: some View {
        Card(title: "Current Room") {
            if !photos.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(photos) { photo in
                            Button {
                                if let index = allPhotos.firstIndex(where: { $0.id == photo.id }) {
                                    viewerSelection = ViewerSelection(index: index)
                                }
                            } label: {
                                PhotoThumbnail(photo: photo, visitID: session.sessionId)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            Menu {
                ForEach(orderedCameraKinds) { kind in
                    Button {
                        takingPhotoKind = kind
                    } label: {
                        Label("\(kind.label) photo", systemImage: "camera")
                    }
                }
            } label: {
                Label(
                    photos.isEmpty ? "Add \(defaultPhotoKind.label) Photos" : "Add Photo",
                    systemImage: "camera.fill"
                )
                .font(.body.weight(.medium))
                .frame(maxWidth: .infinity, minHeight: 44)
            } primaryAction: {
                takingPhotoKind = defaultPhotoKind
            }
            .buttonStyle(.bordered)
        }
    }

    private var orderedCameraKinds: [PhotoKind] {
        defaultPhotoKind == .before ? [.before, .progress, .after] : [.after, .progress, .before]
    }

    private func addPhoto(_ image: UIImage, kind: PhotoKind) {
        guard let photo = PhotoStore.save(image, visitID: session.sessionId, kind: kind) else { return }
        history.addPhoto(photo, to: session.sessionId)
        renderQuote() // quote PDF includes the new photo immediately
        archivePhoto(photo)
    }

    /// Best-effort archive to the backend's permanent project record.
    private func archivePhoto(_ photo: VisitPhoto) {
        guard let jpeg = PhotoStore.jpegData(photo, visitID: session.sessionId) else { return }
        let sessionID = session.sessionId
        let configured = backendURLString
        Task {
            guard let url = await BackendLocator.locate(configuredURLString: configured) else { return }
            do {
                try await HTTPBackendClient(baseURL: url)
                    .uploadPhoto(sessionID: sessionID, kind: photo.kind.rawValue, jpeg: jpeg)
                visitLog.info("Photo archived to backend (\(photo.kind.rawValue))")
            } catch {
                visitLog.warning("Photo archive failed (kept on phone): \(error.localizedDescription)")
            }
        }
    }

    // MARK: sections

    private var heroCard: some View {
        VStack(spacing: 8) {
            if let customer = record?.customerName, !customer.isEmpty {
                Text(customer)
                    .font(.headline)
            }
            Text(visitName)
                .font(.footnote)
                .foregroundStyle(.secondary)
            Text(Format.euroRounded(session.estimate?.suggestedQuotationEur ?? 0))
                .font(.system(size: 58, weight: .heavy, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.yellow)
                .minimumScaleFactor(0.5)
                .lineLimit(1)
                .padding(.top, 2)
            Text("Total Estimate · incl. VAT")
                .font(.footnote.weight(.medium))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 30)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private var breakdownCard: some View {
        Card(title: "Estimate Breakdown") {
            if let e = session.estimate {
                LabeledRow("Labour", detail: Format.hours(e.labourHours), value: Format.euro(e.labourCostEur), symbol: "person.2.fill")
                Divider().padding(.leading, 32)
                LabeledRow("Materials", value: Format.euro(e.materialCostEur), symbol: "shippingbox.fill")
                Divider().padding(.leading, 32)
                preparationRow
                Divider().padding(.leading, 32)
                LabeledRow("Paint", value: Format.litres(e.paintQuantityLitres), symbol: "paintbrush.fill")
                Divider().padding(.leading, 32)
                LabeledRow("Primer", value: Format.litres(e.primerQuantityLitres), symbol: "drop.fill")

                HStack {
                    Text("Total Estimate").font(.headline)
                    Spacer()
                    Text(Format.euro(e.suggestedQuotationEur))
                        .font(.title3.weight(.bold).monospacedDigit())
                        .foregroundStyle(.black)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(Color.yellow)
                .foregroundStyle(.black)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .padding(.top, 8)
            }
        }
    }

    @ViewBuilder
    private var preparationRow: some View {
        if let prep = session.requirements?.preparationRequired, !prep.isEmpty {
            LabeledRow("Preparation", detail: prep.first, value: "Included", symbol: "wrench.and.screwdriver.fill")
        } else {
            LabeledRow("Preparation", detail: "standard surface prep", value: "Included", symbol: "wrench.and.screwdriver.fill")
        }
    }

    private func measurementsCard(_ m: RoomMeasurement) -> some View {
        Card(title: "Room") {
            LabeledRow("Walls (net)", value: Format.squareMetres(m.netWallAreaM2))
            LabeledRow("Ceiling", value: Format.squareMetres(m.ceilingAreaM2))
            LabeledRow("Floor", value: Format.squareMetres(m.floorAreaM2))
            LabeledRow("Measurements", value: m.confidenceScore >= 0.6 ? "Good" : "Check the room")
            if m.notes.contains(where: { $0.contains("bounding box") }) {
                Label("The floor wasn't fully captured — floor and ceiling areas are estimated. Point the camera at the floor during the next scan.", systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
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
            identity: BusinessIdentity.load(),
            record: record
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
    let symbol: String?

    init(_ label: String, detail: String? = nil, value: String, symbol: String? = nil) {
        self.label = label
        self.detail = detail
        self.value = value
        self.symbol = symbol
    }

    var body: some View {
        HStack(spacing: 10) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.footnote)
                    .foregroundStyle(.yellow)
                    .frame(width: 22)
                    .accessibilityHidden(true)
            }
            Text(label)
            if let detail {
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Text(value)
                .font(.body.weight(.medium).monospacedDigit())
        }
        .padding(.vertical, 4)
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
