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
        case .scanning:
            CaptureVisitView(visit: visit)
        case .processing(let stage):
            ProcessingView(stage: stage)
        case .done(let session):
            EstimateView(session: session, visitName: visit.visitName) {
                visit.reset()
            }
        case .failed(let message):
            VisitFailedView(message: message) { visit.reset() }
        }
    }
}

struct VisitFailedView: View {
    let message: String
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 44))
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            Text("Visit Failed")
                .font(.title2.bold())
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Spacer()
            Button(action: onDismiss) {
                Text("Back to Visits")
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.bordered)
            .padding(.horizontal, 24)
            .padding(.bottom, 16)
        }
        .background(Color(.systemBackground))
    }
}
