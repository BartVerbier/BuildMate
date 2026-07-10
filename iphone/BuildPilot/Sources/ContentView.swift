import SwiftUI

struct ContentView: View {
    @StateObject private var visit = VisitController()

    var body: some View {
        switch visit.phase {
        case .idle:
            idleView
        case .scanning:
            scanningView
        case .processing(let label):
            processingView(label)
        case .done(let session):
            EstimateView(session: session) { visit.reset() }
        case .failed(let message):
            failedView(message)
        }
    }

    private var idleView: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "paintbrush.fill")
                .font(.system(size: 56))
                .foregroundStyle(.tint)
            Text("Build Pilot")
                .font(.largeTitle.bold())
            Text("Scan one room while talking with the customer, get a draft estimate.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Spacer()
            Button {
                Task { await visit.startVisit() }
            } label: {
                Text("Start Visit")
                    .font(.title2.bold())
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.borderedProminent)
            .padding(.horizontal, 24)

            HStack {
                Image(systemName: "desktopcomputer")
                    .foregroundStyle(.secondary)
                TextField("Mac backend URL", text: visit.$backendURLString)
                    .textFieldStyle(.roundedBorder)
                    .keyboardType(.URL)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 16)
        }
    }

    private var scanningView: some View {
        ZStack(alignment: .bottom) {
            RoomCaptureViewRepresentable(controller: visit.roomCapture)
                .ignoresSafeArea()
            VStack(spacing: 8) {
                Label("Recording audio", systemImage: "mic.fill")
                    .font(.footnote)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.ultraThinMaterial, in: Capsule())
                Button {
                    visit.finishVisit()
                } label: {
                    Text("Finish Visit")
                        .font(.title2.bold())
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .padding(.horizontal, 24)
            }
            .padding(.bottom, 24)
        }
    }

    private func processingView(_ label: String) -> some View {
        VStack(spacing: 20) {
            ProgressView()
                .controlSize(.large)
            Text(label)
                .font(.headline)
            Text("Keep the app open — transcription runs on your Mac.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding()
    }

    private func failedView(_ message: String) -> some View {
        VStack(spacing: 20) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 44))
                .foregroundStyle(.orange)
            Text("Visit failed")
                .font(.title2.bold())
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            Button("Back to start") { visit.reset() }
                .buttonStyle(.bordered)
        }
        .padding()
    }
}
