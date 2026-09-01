import PhotosUI
import SwiftUI

/// Home: recent visits + one primary action. The screen answers exactly one
/// question — "start a visit, or reopen a recent one?"
struct VisitsHomeView: View {
    @ObservedObject var visit: VisitController
    @ObservedObject private var history: VisitHistoryStore
    @State private var showSettings = false
    /// The reopened visit currently having a spoken change recorded, if any.
    @State private var voiceRevisionRecord: VisitRecord?

    init(visit: VisitController) {
        self.visit = visit
        self.history = visit.history
    }

    var body: some View {
        Group {
            if history.records.isEmpty {
                emptyState
            } else {
                recentVisitsList
            }
        }
        .navigationTitle("Visits")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showSettings = true
                } label: {
                    Image(systemName: "gearshape")
                }
                .accessibilityLabel("Settings")
            }
        }
        .safeAreaInset(edge: .bottom) {
            startButton
        }
        .sheet(isPresented: $showSettings) {
            SettingsSheet(backendURLString: visit.$backendURLString, settings: visit.settings)
        }
        .sheet(item: $voiceRevisionRecord) { record in
            HistoricalRevisionView(record: record, visit: visit) {
                voiceRevisionRecord = nil
            }
            .tint(.yellow)
            .preferredColorScheme(.dark)
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Visits Yet", systemImage: "house")
        } description: {
            Text("Start a visit, walk the room while talking with the customer, and review the draft estimate.")
        }
    }

    private var recentVisitsList: some View {
        List {
            Section("Recent Visits") {
                ForEach(history.records) { record in
                    NavigationLink {
                        EstimateView(
                            session: record.session, visitName: record.name, history: history,
                            // Reopened visits get the SAME workflow as a live visit:
                            // voice "Make Changes" (in place, same session) + Edit Plan.
                            onMakeChanges: { voiceRevisionRecord = record },
                            onEditPlan: { payload, pdfStale, vizStale in
                                Task {
                                    await visit.editHistoricalPlan(
                                        record: record, payload: payload,
                                        pdfStale: pdfStale, visualizationStale: vizStale
                                    )
                                }
                            },
                            onDone: nil
                        )
                    } label: {
                        VisitRow(record: record)
                    }
                }
                .onDelete { history.delete(at: $0) }
            }
        }
        .listStyle(.insetGrouped)
    }

    private var startButton: some View {
        Button {
            visit.draftingNewVisit = true
        } label: {
            Label("Start New Visit", systemImage: "camera.metering.matrix")
                .font(.title3.weight(.bold))
                .frame(maxWidth: .infinity, minHeight: 58)
        }
        .buttonStyle(.borderedProminent)
        .tint(.yellow)
        .foregroundStyle(.black)
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 4)
        .background(.bar)
    }
}

private struct VisitRow: View {
    let record: VisitRecord

    /// Decision 34 surfaced in the list too: a visit whose estimate is not
    /// quotable must not sit behind the same reassuring checkmark as a
    /// finished one.
    private var needsCheck: Bool {
        record.session.estimate?.isQuotable == false
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: needsCheck ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(needsCheck ? .orange : .yellow)
                .font(.title3)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(record.name)
                    .font(.body.weight(.medium))
                HStack(spacing: 4) {
                    Text(record.date, format: .dateTime.day().month().hour().minute())
                    if needsCheck {
                        Text("· Check needed")
                            .foregroundStyle(.orange)
                    } else if (record.revisionCount ?? 0) > 0 {
                        Text("· Edited")
                            .foregroundStyle(.yellow.opacity(0.9))
                    }
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
            Spacer()
            if let quote = record.session.estimate?.suggestedQuotationEur {
                Text(Format.money(quote, currency: record.session.currencyCode, rounded: true))
                    .font(.body.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.yellow)
            }
        }
        .padding(.vertical, 4)
    }
}

struct SettingsSheet: View {
    @Binding var backendURLString: String
    @ObservedObject var settings: ContractorSettingsStore
    @Environment(\.dismiss) private var dismiss
    @StateObject private var discovery = BackendDiscovery()
    @State private var resolvingMacID: String?
    @State private var selectedMacID: String?
    @State private var selectionOK: Bool?
    @State private var showManualEntry = false
    @State private var confirmReset = false

    @State private var logoSelection: PhotosPickerItem?
    @State private var logo: UIImage? = UIImage(contentsOfFile: BusinessIdentity.logoFileURL.path)

    // Version verification: which backend this phone is actually talking to.
    @State private var serverInfo: ServerInfo?
    @State private var loadingServer = false

    /// The currency every money field + the quote reads in.
    private var currency: String { settings.settings.business.currencyCode }

    var body: some View {
        NavigationStack {
            Form {
                businessSection
                pricingSection
                paintSection
                consumablesSection
                quoteSection
                resetSection

                #if DEBUG
                Section {
                    NavigationLink("AR Continuity Spike") { ARContinuitySpikeView() }
                } header: {
                    Text("Debug (internal)")
                } footer: {
                    Text("Proves live AR poses stay in the scan's world frame after RoomPlan finishes. Not shipped in release builds.")
                }
                #endif

                Section {
                    if discovery.macs.isEmpty {
                        HStack(spacing: 12) {
                            ProgressView()
                            Text("Looking for your Mac…")
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        ForEach(discovery.macs) { mac in
                            Button {
                                Task { await select(mac) }
                            } label: {
                                HStack {
                                    Label(mac.name, systemImage: "desktopcomputer")
                                        .foregroundStyle(.primary)
                                    Spacer()
                                    badge(for: mac)
                                }
                            }
                        }
                    }
                } header: {
                    Text("Your Mac")
                } footer: {
                    Text(footerText)
                }

                Section {
                    DisclosureGroup("Enter address manually", isExpanded: $showManualEntry) {
                        TextField("http://192.168.1.23:8787", text: $backendURLString)
                            .keyboardType(.URL)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .onSubmit { Task { await verifyCurrent() } }
                    }
                }

                Section {
                    LabeledContent("App build", value: Self.appVersion)
                    HStack {
                        Text("Backend")
                        Spacer()
                        if loadingServer {
                            ProgressView()
                        } else {
                            Text(serverInfo?.version?.commit ?? "unreachable")
                                .font(.footnote.monospaced())
                                .foregroundStyle(.secondary)
                        }
                    }
                    if let viz = serverInfo?.visualizerAvailable {
                        HStack {
                            Text("Visualization")
                            Spacer()
                            Text(viz ? "Available" : "Unavailable")
                                .foregroundStyle(viz ? .green : .orange)
                        }
                    }
                } header: {
                    Text("Version")
                } footer: {
                    Text("The After image needs Visualization = Available. To be sure the phone and backend run matching code, build the app from the same commit the backend reports.")
                }
                .task { await loadServerInfo() }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.large])
        .onAppear { discovery.start() }
        .onDisappear { discovery.stop() }
        .onChange(of: logoSelection) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self),
                   let image = UIImage(data: data) {
                    logo = image
                    BusinessIdentity.saveLogo(image)
                }
            }
        }
        .confirmationDialog(
            "Reset all business and pricing settings to their defaults?",
            isPresented: $confirmReset, titleVisibility: .visible
        ) {
            Button("Reset to Defaults", role: .destructive) {
                settings.resetToDefaults()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your company details, pricing, paint and materials return to the starting values. Quotes you've already created keep their own saved settings.")
        }
    }

    // MARK: - the four settings sections (kept deliberately small)

    /// 🏢 Business — identity shown on the quote, plus logo and currency. Only
    /// fields a painter actually fills in; blanks are simply left off the quote.
    private var businessSection: some View {
        Section {
            TextField("Company name", text: $settings.settings.business.companyName)
                .textContentType(.organizationName)
            TextField("Your name", text: $settings.settings.business.contactName)
                .textContentType(.name)
            TextField("Phone", text: $settings.settings.business.phone)
                .textContentType(.telephoneNumber)
                .keyboardType(.phonePad)
            TextField("Email", text: $settings.settings.business.email)
                .textContentType(.emailAddress)
                .keyboardType(.emailAddress)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            TextField("Address", text: $settings.settings.business.address, axis: .vertical)
                .lineLimit(1 ... 3)
                .textContentType(.fullStreetAddress)
            TextField("VAT / CVR number", text: $settings.settings.business.vatNumber)
                .autocorrectionDisabled()
            Picker("Currency", selection: $settings.settings.business.currencyCode) {
                ForEach(CurrencyCatalog.options, id: \.code) { option in
                    Text("\(option.name) (\(option.symbol))").tag(option.code)
                }
            }
            PhotosPicker(selection: $logoSelection, matching: .images) {
                HStack {
                    Text(logo == nil ? "Add company logo" : "Change company logo")
                    Spacer()
                    if let logo {
                        Image(uiImage: logo)
                            .resizable()
                            .scaledToFit()
                            .frame(height: 32)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                }
            }
            if logo != nil {
                Button("Remove logo", role: .destructive) {
                    logo = nil
                    BusinessIdentity.saveLogo(nil)
                }
            }
        } header: {
            Text("🏢 Business")
        } footer: {
            Text("Shown on every quote. Leave anything blank and it's simply left off.")
        }
    }

    /// 💰 Pricing — one number: what an hour of labour costs.
    private var pricingSection: some View {
        Section {
            MoneyField(title: "Hourly Rate", currencyCode: currency,
                       amount: $settings.settings.pricing.hourlyRate)
        } header: {
            Text("💰 Pricing")
        }
    }

    /// 🎨 Paint — just paint price and coverage.
    private var paintSection: some View {
        Section {
            MoneyField(title: "Paint Price", currencyCode: currency,
                       amount: $settings.settings.paint.paintCostPerLitre, footnote: "per litre")
            DecimalField(title: "Coverage", value: $settings.settings.paint.paintCoverageM2PerLitre,
                         unit: "m²/L", minimum: 0.1)
        } header: {
            Text("🎨 Paint")
        } footer: {
            Text("Coverage must be greater than zero — it converts area into litres.")
        }
    }

    /// 🧰 Consumables — one flat cost for everything used up on a normal job.
    private var consumablesSection: some View {
        Section {
            MoneyField(title: "Consumables Cost", currencyCode: currency,
                       amount: $settings.settings.materials.consumablesAllowance)
        } header: {
            Text("🧰 Consumables")
        } footer: {
            Text("One value for tape, plastic, paper, roller sleeves, sandpaper and other small consumables.")
        }
    }

    /// 📄 Quote — the two commercial figures on the final price.
    private var quoteSection: some View {
        Section {
            PercentField(title: "VAT", fraction: $settings.settings.pricing.vatFraction)
            MoneyField(title: "Minimum charge", currencyCode: currency,
                       amount: $settings.settings.pricing.minimumCharge,
                       footnote: "Price floor before VAT. 0 = no minimum.")
        } header: {
            Text("📄 Quote")
        }
    }

    private var resetSection: some View {
        Section {
            Button("Reset to Defaults", role: .destructive) {
                confirmReset = true
            }
        }
    }

    /// Per-row state: spinner while this Mac is being tried, then a green
    /// check (connected, now selected) or red cross (couldn't connect).
    @ViewBuilder
    private func badge(for mac: BackendDiscovery.DiscoveredMac) -> some View {
        if resolvingMacID == mac.id {
            ProgressView()
        } else if selectedMacID == mac.id, let ok = selectionOK {
            Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(ok ? Color.yellow : Color.red)
        }
    }

    private var footerText: String {
        if selectionOK == true {
            return "Connected. This Mac will receive your visits."
        }
        if selectionOK == false {
            return "Couldn't connect to that Mac. Check Build Pilot is running on it, then tap it again."
        }
        return "Open BuildMate on your Mac and it appears here automatically. Both devices must be on the same Wi-Fi. Tap your Mac to connect."
    }

    private func select(_ mac: BackendDiscovery.DiscoveredMac) async {
        resolvingMacID = mac.id
        selectedMacID = mac.id
        selectionOK = nil
        defer { resolvingMacID = nil }

        guard let url = await BackendDiscovery.resolve(mac) else {
            visitLog.error("Settings: could not resolve \(mac.id)")
            selectionOK = false
            return
        }
        let reachable = await HTTPBackendClient(baseURL: url).isReachable()
        visitLog.info("Settings: \(mac.id) → \(url.absoluteString), reachable: \(reachable)")
        if reachable {
            backendURLString = url.absoluteString
            selectionOK = true
        } else {
            selectionOK = false
        }
    }

    private func verifyCurrent() async {
        guard let url = URL(string: backendURLString) else {
            selectionOK = false
            return
        }
        selectionOK = await HTTPBackendClient(baseURL: url).isReachable()
    }

    /// The app's own version: marketing version, build number, and the git SHA
    /// if a build stamped one into the Info.plist (falls back gracefully).
    private static var appVersion: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        if let sha = AppConfig.string("GitSHA") {
            return "\(short) · \(sha)"
        }
        return "\(short) (\(build))"
    }

    private func loadServerInfo() async {
        loadingServer = true
        defer { loadingServer = false }
        guard let url = await BackendLocator.locate(configuredURLString: backendURLString) else { return }
        serverInfo = await HTTPBackendClient(baseURL: url).serverInfo()
    }
}
