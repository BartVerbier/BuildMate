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
                        EstimateView(session: record.session, visitName: record.name, onDone: nil)
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
            Task { await visit.startVisit() }
        } label: {
            Label("Start New Visit", systemImage: "camera.metering.matrix")
                .font(.title3.weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: 56)
        }
        .buttonStyle(.borderedProminent)
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
                .foregroundStyle(.green)
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
                    .foregroundStyle(.green)
            }
        }
        .padding(.vertical, 4)
    }
}

struct SettingsSheet: View {
    @Binding var backendURLString: String
    @Environment(\.dismiss) private var dismiss
    @StateObject private var discovery = BackendDiscovery()
    @State private var selectedOK: Bool?
    @State private var showManualEntry = false

    // Shown on every quote the customer receives. No CRM — just identity.
    @AppStorage("business.company") private var companyName = ""
    @AppStorage("business.painter") private var painterName = ""
    @AppStorage("business.phone") private var businessPhone = ""
    @AppStorage("business.email") private var businessEmail = ""

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
                                    connectionBadge
                                }
                            }
                        }
                    }
                } header: {
                    Text("Your Mac")
                } footer: {
                    Text("Open Build Pilot on your Mac and it appears here automatically. Both devices must be on the same Wi-Fi.")
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
    }

    @ViewBuilder
    private var connectionBadge: some View {
        if let ok = selectedOK {
            Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(ok ? .green : .red)
        }
    }

    private func select(_ mac: BackendDiscovery.DiscoveredMac) async {
        selectedOK = nil
        guard let url = await BackendDiscovery.resolve(mac) else {
            selectedOK = false
            return
        }
        backendURLString = url.absoluteString
        await verifyCurrent()
    }

    private func verifyCurrent() async {
        guard let url = URL(string: backendURLString) else {
            selectedOK = false
            return
        }
        selectedOK = await VisitController.isReachable(url)
    }
}
