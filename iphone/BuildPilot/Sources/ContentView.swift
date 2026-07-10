import SwiftUI

/// Root: the Visits home lives in a NavigationStack; an active visit
/// (scanning → processing → estimate) is a full-screen flow above it.
struct ContentView: View {
    @StateObject private var visit = VisitController()

    private var visitFlowPresented: Binding<Bool> {
        Binding(
            get: { visit.phase.isActiveVisit },
            set: { presented in if !presented { visit.reset() } }
        )
    }

    var body: some View {
        NavigationStack {
            VisitsHomeView(visit: visit)
        }
        .fullScreenCover(isPresented: visitFlowPresented) {
            visitFlow
        }
        .tint(.green)
        .preferredColorScheme(.dark)
    }

    @ViewBuilder
    private var visitFlow: some View {
        switch visit.phase {
        case .idle:
            EmptyView()
        case .connecting:
            ConnectingView()
        case .scanning:
            CaptureVisitView(visit: visit)
        case .processing(let stage):
            ProcessingView(stage: stage)
        case .done(let session):
            if visit.readbackConfirmed {
                EstimateView(session: session, visitName: visit.visitName, history: visit.history) {
                    visit.reset()
                }
            } else {
                ReadbackView(
                    session: session,
                    onShowQuote: { withAnimation { visit.readbackConfirmed = true } },
                    onScanAgain: { visit.reset() }
                )
            }
        case .failed(let message, let canRetry):
            VisitFailedView(
                message: message,
                onRetry: canRetry ? { Task { await visit.retryUpload() } } : nil,
                onDismiss: { visit.reset() }
            )
        }
    }
}

/// Brief preflight while the app finds and checks the Mac.
struct ConnectingView: View {
    var body: some View {
        VStack(spacing: 16) {
            ProgressView()
                .controlSize(.large)
            Text("Connecting to your Mac…")
                .font(.headline)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemGroupedBackground))
    }
}

struct VisitFailedView: View {
    let message: String
    let onRetry: (() -> Void)?
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: onRetry != nil ? "wifi.exclamationmark" : "exclamationmark.triangle.fill")
                .font(.system(size: 44))
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            Text(onRetry != nil ? "Couldn't Send to Your Mac" : "Something Went Wrong")
                .font(.title2.bold())
                .multilineTextAlignment(.center)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Spacer()
            VStack(spacing: 10) {
                if let onRetry {
                    Button(action: onRetry) {
                        Label("Try Again", systemImage: "arrow.clockwise")
                            .font(.title3.weight(.semibold))
                            .frame(maxWidth: .infinity, minHeight: 56)
                    }
                    .buttonStyle(.borderedProminent)
                }
                Button(action: onDismiss) {
                    Text(onRetry != nil ? "Discard Visit" : "Back to Visits")
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.bordered)
                .tint(onRetry != nil ? .red : .green)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 16)
        }
        .background(Color(.systemGroupedBackground))
    }
}
