import SwiftUI

/// Root: the Visits home lives in a NavigationStack; an active visit
/// (scanning → processing → estimate) is a full-screen flow above it.
struct ContentView: View {
    @StateObject private var visit = VisitController()

    private var visitFlowPresented: Binding<Bool> {
        Binding(
            get: { visit.draftingNewVisit || visit.phase.isActiveVisit },
            set: { presented in
                if !presented {
                    visit.draftingNewVisit = false
                    visit.reset()
                }
            }
        )
    }

    var body: some View {
        NavigationStack {
            VisitsHomeView(visit: visit)
        }
        .fullScreenCover(isPresented: visitFlowPresented) {
            visitFlow
        }
        .tint(.yellow)
        .preferredColorScheme(.dark)
    }

    @ViewBuilder
    private var visitFlow: some View {
        if visit.draftingNewVisit {
            NewVisitView(
                onStart: { customer in Task { await visit.startVisit(customer: customer) } },
                onCancel: { visit.draftingNewVisit = false }
            )
            .tint(.yellow)
            .preferredColorScheme(.dark)
        } else {
            phaseFlow
        }
    }

    @ViewBuilder
    private var phaseFlow: some View {
        switch visit.phase {
        case .idle:
            EmptyView()
        case .connecting:
            ConnectingView()
        case .scanning:
            CaptureVisitView(visit: visit)
        case .revising(let session):
            RevisionRecordingView(session: session, visit: visit)
        case .scanReview(let status):
            ScanReviewView(visit: visit, status: status)
        case .processing(let stage):
            ProcessingView(stage: stage)
        case .done(let session):
            if visit.readbackConfirmed {
                EstimateView(
                    session: session,
                    visitName: visit.visitName,
                    history: visit.history,
                    visualizationPending: visit.visualizationPending,
                    renderError: visit.renderError,
                    onRetryRender: { visit.retryRenders() },
                    changes: visit.lastChanges,
                    onMakeChanges: { Task { await visit.startRevision() } },
                    onRescan: { Task { await visit.rescan() } },
                    onEditPlan: { payload, pdfStale, vizStale in
                        Task { await visit.savePlanEdit(payload: payload, pdfStale: pdfStale, visualizationStale: vizStale) }
                    }
                ) {
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
                .tint(onRetry != nil ? .red : .yellow)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 16)
        }
        .background(Color(.systemGroupedBackground))
    }
}
