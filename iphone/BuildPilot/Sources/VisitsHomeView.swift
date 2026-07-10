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
    @State private var checkResult: Bool?
    @State private var checking = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("http://192.168.1.23:8787", text: $backendURLString)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                } header: {
                    Text("Mac Address")
                } footer: {
                    Text("Your Mac runs the Build Pilot backend on the same Wi-Fi network. Find its address in System Settings → Wi-Fi → Details.")
                }

                Section {
                    Button {
                        Task { await testConnection() }
                    } label: {
                        HStack {
                            Text("Test Connection")
                            Spacer()
                            if checking {
                                ProgressView()
                            } else if let ok = checkResult {
                                Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                                    .foregroundStyle(ok ? .green : .red)
                            }
                        }
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
        .presentationDetents([.medium])
    }

    private func testConnection() async {
        checking = true
        defer { checking = false }
        guard let url = URL(string: backendURLString)?.appendingPathComponent("health") else {
            checkResult = false
            return
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            checkResult = (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            checkResult = false
        }
    }
}
