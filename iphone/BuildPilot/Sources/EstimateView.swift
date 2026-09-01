import SwiftUI

/// Draft estimate review. The price is the hero; everything below it exists
/// to build confidence in that number. Used in the visit flow (onDone set)
/// and when reopening a recent visit (onDone nil, plain navigation).
struct EstimateView: View {
    /// The snapshot this view was created with. The displayed `session`
    /// (computed below) prefers the latest from history, so an in-place edit —
    /// live or on a reopened visit — refreshes this screen immediately.
    let passedSession: SessionResponse
    let visitName: String
    @ObservedObject var history: VisitHistoryStore
    var visualizationPending: Bool = false
    var renderError: String? = nil
    var onRetryRender: (() -> Void)? = nil
    var changes: [String] = []
    var onMakeChanges: (() -> Void)? = nil
    /// Re-capture the room geometry (live visit only). Nil on reopened visits.
    var onRescan: (() -> Void)? = nil
    /// Save manual plan edits: (payload, pdfStale, vizStale). Provided on the
    /// live visit and on reopened history; nil disables editing.
    var onEditPlan: ((PlanEditPayload?, Bool, Bool) -> Void)? = nil
    let onDone: (() -> Void)?

    init(session: SessionResponse, visitName: String, history: VisitHistoryStore,
         visualizationPending: Bool = false, renderError: String? = nil,
         onRetryRender: (() -> Void)? = nil, changes: [String] = [],
         onMakeChanges: (() -> Void)? = nil, onRescan: (() -> Void)? = nil,
         onEditPlan: ((PlanEditPayload?, Bool, Bool) -> Void)? = nil,
         onDone: (() -> Void)?) {
        self.passedSession = session
        self.visitName = visitName
        self._history = ObservedObject(wrappedValue: history)
        self.visualizationPending = visualizationPending
        self.renderError = renderError
        self.onRetryRender = onRetryRender
        self.changes = changes
        self.onMakeChanges = onMakeChanges
        self.onRescan = onRescan
        self.onEditPlan = onEditPlan
        self.onDone = onDone
    }

    /// The current session — the latest from history (so edits refresh instantly),
    /// falling back to the snapshot before the visit is in history.
    private var session: SessionResponse {
        history.record(for: passedSession.sessionId)?.session ?? passedSession
    }

    @State private var quoteURL: URL?
    @State private var takingPhotoKind: PhotoKind?
    @State private var editingCustomer = false
    @State private var viewerSelection: ViewerSelection?
    @State private var showShareOptions = false
    @State private var showPreview = false
    @State private var showMail = false
    @State private var showSystemShare = false
    @State private var showEditPlan = false
    @State private var accepted = false

    struct ViewerSelection: Identifiable {
        let id = UUID()
        let index: Int
    }
    @AppStorage("backendURL") private var backendURLString = ""

    private var record: VisitRecord? { history.record(for: session.sessionId) }
    /// The business identity for THIS quote: the frozen snapshot when the visit
    /// has one (so a historical PDF keeps the details it was created with), else
    /// the live settings (a brand-new visit, or a record from before snapshots).
    private var identity: BusinessIdentity {
        if let snapshot = record?.businessSnapshot {
            return BusinessIdentity.from(snapshot: snapshot, visitID: session.sessionId)
        }
        return BusinessIdentity.load()
    }
    private var allPhotos: [VisitPhoto] { record?.photos ?? [] }
    /// Camera photos only — the AI renders have their own card.
    private var photos: [VisitPhoto] { allPhotos.filter { !$0.kind.isRender } }
    private var visualization: VisitPhoto? { allPhotos.last { $0.kind == .visualization } }
    private var preparationRender: VisitPhoto? { allPhotos.last { $0.kind == .preparation } }
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
            // The AI renders arrive asynchronously, after the screen is already
            // shown. Re-render the PDF the moment they land so Share/Preview
            // always includes the latest — never rely on a subview's onAppear.
            .onChange(of: visualization?.id) { renderQuote() }
            .onChange(of: preparationRender?.id) { renderQuote() }
            .modifier(WrapInStackIfNeeded(needsStack: onDone != nil))
    }

    private var content: some View {
        ScrollView {
            VStack(spacing: 16) {
                changesCard
                // ABOVE the price: a specific-wall request that couldn't be
                // grounded means the hero number prices the WHOLE room —
                // that must never read as a correctly scoped quote.
                notQuotableCard
                wallScopeAlertCard
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

    // MARK: change summary (after a revision)

    @ViewBuilder
    private var changesCard: some View {
        if !changes.isEmpty {
            Card(title: "What Changed") {
                ForEach(changes, id: \.self) { change in
                    Label(change, systemImage: "checkmark")
                        .font(.body.weight(.medium))
                        .foregroundStyle(.yellow)
                }
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
                    stageArrow
                }
                if let prep = preparationRender,
                   let prepImage = PhotoStore.load(prep, visitID: session.sessionId) {
                    transformationImage(prepImage, label: "PREPARED", photo: prep)
                    stageArrow
                }
                transformationImage(vizImage, label: "FINISHED", photo: visualization)
                Text("AI visualization based on your room — final result may vary slightly.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if record?.visualizationStale == true {
                    HStack(spacing: 8) {
                        Label("Preview may be outdated after your edits.", systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                        Spacer()
                        if onRetryRender != nil {
                            Button("Regenerate") {
                                onRetryRender?()
                                history.clearStale(visualization: true, for: session.sessionId)
                            }
                            .font(.caption.weight(.semibold))
                        }
                    }
                }
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
        } else if let renderError {
            Card(title: "Proposed Result") {
                Label(renderError, systemImage: "photo.badge.exclamationmark")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if let onRetryRender {
                    Button {
                        onRetryRender()
                    } label: {
                        Label("Try Again", systemImage: "arrow.clockwise")
                            .font(.body.weight(.medium))
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.bordered)
                    .tint(.yellow)
                }
            }
        }
    }

    private var stageArrow: some View {
        Image(systemName: "arrow.down")
            .font(.title3.weight(.bold))
            .foregroundStyle(.yellow)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 2)
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
                    .background(label == "FINISHED" ? Color.yellow : Color.black.opacity(0.55))
                    .foregroundStyle(label == "FINISHED" ? .black : .white)
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

    /// The completeness gate (Decision 34): the scan did not capture the
    /// whole room and nobody has verified the measurements, so this draft
    /// prices only what was scanned and must not go out as a quotation.
    /// Clears itself after a rescan or the Edit Plan verification toggle.
    @ViewBuilder
    private var notQuotableCard: some View {
        if let estimate = session.estimate, !estimate.isQuotable {
            VStack(alignment: .leading, spacing: 10) {
                Label("Not ready to quote", systemImage: "exclamationmark.octagon.fill")
                    .font(.headline)
                    .foregroundStyle(.red)
                Text(estimate.notQuotableReason ??
                     "The scan did not capture the whole room — rescan, or verify the measurements on site before quoting.")
                    .font(.subheadline)
                if onEditPlan != nil {
                    Button {
                        showEditPlan = true
                    } label: {
                        Label("Verify Measurements", systemImage: "checkmark.seal")
                            .font(.body.weight(.semibold))
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                }
            }
            .padding(14)
            .background(.red.opacity(0.12), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.red.opacity(0.55), lineWidth: 1.5))
            .accessibilityElement(children: .combine)
        }
    }

    /// The whole-room-fallback warning (WallScopeAlert). Routes straight to
    /// Edit Plan's existing painted-wall selection; the alert clears itself
    /// once paintedWallIds is non-empty after the re-estimate.
    @ViewBuilder
    private var wallScopeAlertCard: some View {
        if let message = WallScopeAlert.message(for: session.requirements) {
            VStack(alignment: .leading, spacing: 10) {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.orange)
                if onEditPlan != nil {
                    Button {
                        showEditPlan = true
                    } label: {
                        Label("Choose the Wall(s)", systemImage: "square.split.bottomrightquarter")
                            .font(.body.weight(.semibold))
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                }
            }
            .padding(14)
            .background(.orange.opacity(0.15), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.orange.opacity(0.6), lineWidth: 1.5))
            .accessibilityElement(children: .combine)
        }
    }

    private var heroCard: some View {
        VStack(spacing: 8) {
            if let customer = record?.customerName, !customer.isEmpty {
                Text(customer)
                    .font(.headline)
            }
            Text(visitName)
                .font(.footnote)
                .foregroundStyle(.secondary)
            Text(Format.money(session.estimate?.suggestedQuotationEur ?? 0, currency: session.currencyCode, rounded: true))
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
                LabeledRow("Labour", detail: Format.hours(e.labourHours), value: Format.money(e.labourCostEur, currency: session.currencyCode), symbol: "person.2.fill")
                Divider().padding(.leading, 32)
                LabeledRow("Materials", value: Format.money(e.materialCostEur, currency: session.currencyCode), symbol: "shippingbox.fill")
                Divider().padding(.leading, 32)
                preparationRow
                Divider().padding(.leading, 32)
                LabeledRow("Paint", value: Format.litres(e.paintQuantityLitres), symbol: "paintbrush.fill")
                Divider().padding(.leading, 32)
                LabeledRow("Primer", value: Format.litres(e.primerQuantityLitres), symbol: "drop.fill")

                HStack {
                    Text("Total Estimate").font(.headline)
                    Spacer()
                    Text(Format.money(e.suggestedQuotationEur, currency: session.currencyCode))
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
            LabeledRow("Preparation", detail: preparationDetail, value: "Included", symbol: "wrench.and.screwdriver.fill")
        }
    }

    /// What preparation means in THIS room, from the scan's object counts.
    private var preparationDetail: String {
        let movable = session.measurements?.movableObjects ?? 0
        let fixed = session.measurements?.fixedObjects ?? 0
        var parts: [String] = []
        if movable > 0 { parts.append("\(movable) item\(movable == 1 ? "" : "s") moved") }
        if fixed > 0 { parts.append("\(fixed) protected in place") }
        return parts.isEmpty ? "standard surface prep" : parts.joined(separator: " · ")
    }

    private func measurementsCard(_ m: RoomMeasurement) -> some View {
        Card(title: "Room") {
            // Smallest-possible confirmation: when the conversation limited
            // painting to specific walls, say so where the painter reads back
            // the quote — one glance verifies the understanding.
            if let sel = session.wallSelection {
                LabeledRow(
                    "Painting",
                    value: "\(sel.selected) of \(sel.total) walls · \(Format.squareMetres(sel.areaM2))",
                    symbol: "scope"
                )
                Divider().padding(.vertical, 2)
            }
            LabeledRow("Walls (net)", value: Format.squareMetres(m.netWallAreaM2))
            LabeledRow("Ceiling", value: Format.squareMetres(m.ceilingAreaM2))
            LabeledRow("Floor", value: Format.squareMetres(m.floorAreaM2))

            if let confidence = session.confidence {
                Divider().padding(.vertical, 2)
                ConfidenceCard(report: confidence)
            } else {
                // Legacy fallback for visits stored before the confidence engine.
                LabeledRow("Measurements", value: m.confidenceScore >= 0.6 ? "Good" : "Check the room")
                if m.notes.contains(where: { $0.contains("bounding box") }) {
                    Label("The floor wasn't fully captured — floor and ceiling areas are estimated. Point the camera at the floor during the next scan.", systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
                if m.notes.contains(where: { $0.contains("uncaptured walls") }) {
                    Label("Some walls weren't captured in the scan — their area has been estimated from the room's shape. Verify the wall measurement, or rescan walking the full perimeter with every wall in view.", systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            }

            // Live visit only: offer a rescan when the scan under-captured the
            // room. The warning above stays visible; this adds the action.
            if onRescan != nil && scanNeedsAttention {
                Button { onRescan?() } label: {
                    Label("Rescan Room", systemImage: "arrow.clockwise")
                        .font(.body.weight(.medium))
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.bordered)
                .tint(.yellow)
                .padding(.top, 2)
            }
        }
    }

    /// The scan under-captured the room (low confidence, or walls/floor were
    /// estimated) — the painter should be offered a rescan.
    private var scanNeedsAttention: Bool {
        guard let m = session.measurements else { return false }
        if let c = session.confidence { return c.band != "high" }
        return m.confidenceScore < 0.6
            || m.notes.contains { $0.contains("uncaptured walls") || $0.contains("bounding box") }
    }

    @ViewBuilder
    private func requirementsCards(_ r: RequirementExtraction) -> some View {
        Card(title: "Project Summary") {
            Text(ConversationSummary.sentence(for: r))
                .font(.body)
                .lineSpacing(3)
        }
        Card(title: "Scope of Work") {
            if let notice = ScopeNotice.message(for: r) {
                // Silent walkthrough: every stage below is a default, not
                // something the customer asked for — say so, don't hide it.
                Label(notice, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.orange)
                    .padding(.bottom, 6)
            }
            ForEach(WorkPlan.stages(for: r, measurements: session.measurements)) { stage in
                VStack(alignment: .leading, spacing: 6) {
                    Text(stage.title.uppercased())
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.yellow)
                        .kerning(0.8)
                    BulletList(items: stage.items)
                }
                .padding(.bottom, 6)
            }
        }
        if let e = session.estimate {
            durationCard(e)
        }
        if !r.exclusions.isEmpty {
            Card(title: "Not Included") { BulletList(items: r.exclusions) }
        }
        recommendationsCard(r)
        if !r.specialNotes.isEmpty {
            Card(title: "Customer Notes") { BulletList(items: r.specialNotes) }
        }
    }

    private func durationCard(_ e: EstimateDraft) -> some View {
        let duration = WorkPlan.duration(labourHours: e.labourHours)
        return Card(title: "Project Duration") {
            LabeledRow("Preparation", value: duration.preparation, symbol: "clock.fill")
            LabeledRow("Painting", value: duration.painting, symbol: "paintbrush.fill")
            LabeledRow("Drying", value: duration.drying, symbol: "wind")
            Divider().padding(.vertical, 2)
            LabeledRow("Total duration", value: duration.total, symbol: "calendar")
        }
    }

    @ViewBuilder
    private func recommendationsCard(_ r: RequirementExtraction) -> some View {
        let suggestions = WorkPlan.recommendations(for: r)
        if !suggestions.isEmpty {
            Card(title: "Worth Considering") {
                ForEach(suggestions, id: \.self) { item in
                    Label(item, systemImage: "plus.circle")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Text("Optional — not included in this quote.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
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

    /// A plan is confirmed once the painter taps Confirm (persisted), or in this
    /// session. "modified" (edited after confirming) still reads as confirmed.
    private var isConfirmed: Bool {
        let s = record?.planState
        return s == "confirmed" || s == "modified" || accepted
    }

    /// Shown when a plan edit made the generated PDF out of date.
    private var stalePdfBanner: some View {
        VStack(spacing: 6) {
            Label("Plan updated — the quote PDF is out of date.", systemImage: "exclamationmark.triangle.fill")
                .font(.footnote.weight(.medium))
                .foregroundStyle(.orange)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                renderQuote()
                history.clearStale(pdf: true, for: session.sessionId)
            } label: {
                Label("Regenerate Quote PDF", systemImage: "arrow.clockwise")
                    .font(.body.weight(.medium))
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.bordered)
            .tint(.orange)
        }
        .padding(10)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var shareBar: some View {
        VStack(spacing: 10) {
            if record?.pdfStale == true { stalePdfBanner }
            if onEditPlan != nil {
                HStack(spacing: 10) {
                    Button {
                        history.setPlanState("confirmed", for: session.sessionId)
                        withAnimation { accepted = true }
                    } label: {
                        Label(isConfirmed ? "Plan Confirmed" : "Confirm Plan",
                              systemImage: isConfirmed ? "checkmark.circle.fill" : "checkmark.circle")
                            .font(.body.weight(.semibold))
                            .frame(maxWidth: .infinity, minHeight: 46)
                    }
                    .buttonStyle(.bordered)
                    .tint(.green)

                    Button { showEditPlan = true } label: {
                        Label("Edit Plan", systemImage: "slider.horizontal.3")
                            .font(.body.weight(.semibold))
                            .frame(maxWidth: .infinity, minHeight: 46)
                    }
                    .buttonStyle(.bordered)
                    .tint(.yellow)
                }
            }
            if onMakeChanges != nil {
                Button { onMakeChanges?() } label: {
                    Label("Make Changes by Voice", systemImage: "mic.fill")
                        .font(.body.weight(.medium))
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.bordered)
                .tint(.yellow)
            }
            Button {
                showShareOptions = true
            } label: {
                Label("Share Quote", systemImage: "square.and.arrow.up")
                    .font(.title3.weight(.bold))
                    .frame(maxWidth: .infinity, minHeight: 54)
            }
            .buttonStyle(.borderedProminent)
            .tint(.yellow)
            .foregroundStyle(.black)
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 4)
        .background(.bar)
        .sheet(isPresented: $showEditPlan) {
            EditPlanView(session: session) { payload, pdfStale, vizStale in
                onEditPlan?(payload, pdfStale, vizStale)
            }
        }
        .confirmationDialog("Share Quote", isPresented: $showShareOptions, titleVisibility: .visible) {
            if quoteURL != nil {
                Button("Preview Quote") { showPreview = true }
            }
            if MailComposer.canSendMail {
                Button("Email to Customer") { showMail = true }
            }
            Button("Share via…") { showSystemShare = true }
            Button("Cancel", role: .cancel) {}
        }
        .sheet(isPresented: $showPreview) {
            if let quoteURL {
                QuotePreview(url: quoteURL).ignoresSafeArea()
            }
        }
        .sheet(isPresented: $showMail) {
            let email = MailComposer.quoteEmail(
                customer: record?.customerName ?? visitName,
                company: identity.companyName.isEmpty ? "Your painting team" : identity.companyName
            )
            MailComposer(
                to: record?.customerEmail ?? "",
                subject: email.subject,
                body: email.body,
                attachment: quoteURL
            )
            .ignoresSafeArea()
        }
        .sheet(isPresented: $showSystemShare) {
            if let quoteURL {
                ActivityShare(items: [quoteURL])
            } else {
                ActivityShare(items: [quoteText])
            }
        }
    }

    private var quoteText: String {
        var lines: [String] = []
        if !identity.companyName.isEmpty { lines.append(identity.companyName) }
        if !identity.contactLine.isEmpty { lines.append(identity.contactLine) }
        lines.append("Painting Estimate — \(visitName)")
        if session.estimate?.isQuotable == false {
            lines.append("DRAFT — NOT FOR QUOTATION: the scan did not capture the whole room; measurements are unverified.")
        }
        if let e = session.estimate {
            lines.append("Suggested price (incl. VAT): \(Format.money(e.suggestedQuotationEur, currency: session.currencyCode))")
            lines.append("Labour: \(Format.hours(e.labourHours)) · \(Format.money(e.labourCostEur, currency: session.currencyCode))")
            lines.append("Materials: \(Format.money(e.materialCostEur, currency: session.currencyCode))")
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
            identity: identity,
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

/// Renders the backend's confidence report: a 0–100 score with an explainable
/// breakdown. Signal-agnostic — it draws whatever signals and tips the backend
/// sends, so new capture-quality signals appear here with no change.
private struct ConfidenceCard: View {
    let report: ConfidenceReport

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.footnote)
                    .foregroundStyle(color)
                    .frame(width: 22)
                    .accessibilityHidden(true)
                Text("Scan confidence")
                Spacer()
                Text("\(report.score)%")
                    .font(.body.weight(.semibold).monospacedDigit())
                    .foregroundStyle(color)
            }
            ProgressView(value: Double(report.score), total: 100)
                .tint(color)
            Text(report.headline)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            if !report.tips.isEmpty {
                ForEach(report.tips, id: \.self) { tip in
                    Label(tip, systemImage: "arrow.up.forward.circle")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            }

            if !report.signals.isEmpty {
                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(report.signals) { signal in
                            HStack(alignment: .top, spacing: 8) {
                                Text("\(Int((signal.score * 100).rounded()))%")
                                    .font(.caption.monospacedDigit().weight(.medium))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 40, alignment: .trailing)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(signal.label).font(.footnote.weight(.medium))
                                    Text(signal.detail)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    .padding(.top, 6)
                } label: {
                    Text("What we checked")
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var color: Color {
        switch report.band {
        case "high": return .green
        case "medium": return .yellow
        default: return .orange
        }
    }

    private var icon: String {
        switch report.band {
        case "high": return "checkmark.seal.fill"
        case "medium": return "checkmark.circle"
        default: return "exclamationmark.triangle.fill"
        }
    }
}

/// System share sheet for the "Share via…" fallback.
private struct ActivityShare: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
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
