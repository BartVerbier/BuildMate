import PhotosUI
import SwiftUI

/// Home: recent visits + one primary action. The screen answers exactly one
/// question — "start a visit, or reopen a recent one?"
struct VisitsHomeView: View {
    @ObservedObject var visit: VisitController
    @ObservedObject private var history: VisitHistoryStore
    @State private var showSettings = false

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
            SettingsSheet(backendURLString: visit.$backendURLString)
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
                        EstimateView(session: record.session, visitName: record.name, history: history, onDone: nil)
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

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.yellow)
                .font(.title3)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(record.name)
                    .font(.body.weight(.medium))
                Text(record.date, format: .dateTime.day().month().hour().minute())
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let quote = record.session.estimate?.suggestedQuotationEur {
                Text(Format.euroRounded(quote))
                    .font(.body.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.yellow)
            }
        }
        .padding(.vertical, 4)
    }
}

struct SettingsSheet: View {
    @Binding var backendURLString: String
    @Environment(\.dismiss) private var dismiss
    @StateObject private var discovery = BackendDiscovery()
    @State private var resolvingMacID: String?
    @State private var selectedMacID: String?
    @State private var selectionOK: Bool?
    @State private var showManualEntry = false

    // Shown on every quote the customer receives. No CRM — just identity.
    @AppStorage("business.company") private var companyName = ""
    @AppStorage("business.painter") private var painterName = ""
    @AppStorage("business.phone") private var businessPhone = ""
    @AppStorage("business.email") private var businessEmail = ""
    @AppStorage("business.terms") private var terms = BusinessIdentity.defaultTerms
    @State private var logoSelection: PhotosPickerItem?
    @State private var logo: UIImage? = UIImage(contentsOfFile: BusinessIdentity.logoFileURL.path)

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Company name", text: $companyName)
                        .textContentType(.organizationName)
                    TextField("Your name", text: $painterName)
                        .textContentType(.name)
                    TextField("Phone", text: $businessPhone)
                        .textContentType(.telephoneNumber)
                        .keyboardType(.phonePad)
                    TextField("Email", text: $businessEmail)
                        .textContentType(.emailAddress)
                        .keyboardType(.emailAddress)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                } header: {
                    Text("Your Business")
                } footer: {
                    Text("Shown on every quote you share with a customer.")
                }

                Section {
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
                    Text("Company Logo")
                } footer: {
                    Text("Appears at the top of the quote PDF.")
                }

                Section {
                    TextEditor(text: $terms)
                        .frame(minHeight: 90)
                        .font(.footnote)
                } header: {
                    Text("Terms & Conditions")
                } footer: {
                    Text("Printed at the bottom of every quote.")
                }

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
}
