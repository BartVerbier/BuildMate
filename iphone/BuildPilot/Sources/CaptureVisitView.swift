import SwiftUI

/// The capture screen: Apple's native RoomPlan experience full-bleed, with
/// exactly two of our own controls — a live recording indicator and Finish.
struct CaptureVisitView: View {
    @ObservedObject var visit: VisitController
    @State private var confirmCancel = false
    /// A brief coaching hint over Apple's own scan overlay. Fades after a few
    /// seconds so it guides the first moments without obscuring the room.
    @State private var showScanHint = true

    var body: some View {
        ZStack {
            RoomCaptureViewRepresentable(controller: visit.roomCapture)
                .ignoresSafeArea()

            VStack {
                topBar
                if showScanHint { scanHint }
                Spacer()
                finishButton
            }
        }
        .statusBarHidden()
        .task {
            // Guidance toward full-perimeter coverage — the single biggest
            // driver of measurement confidence — then get out of the way.
            try? await Task.sleep(for: .seconds(7))
            withAnimation(.easeOut(duration: 0.4)) { showScanHint = false }
        }
        .confirmationDialog(
            visit.isRescanning ? "Stop re-scanning?" : "Discard this visit?",
            isPresented: $confirmCancel,
            titleVisibility: .visible
        ) {
            Button(visit.isRescanning ? "Stop — keep current quote" : "Discard Visit",
                   role: .destructive) { visit.cancelVisit() }
            Button("Keep Scanning", role: .cancel) {}
        } message: {
            Text(visit.isRescanning
                 ? "Your existing quote stays exactly as it is."
                 : "The room scan and audio recording will be deleted.")
        }
    }

    private var topBar: some View {
        HStack {
            Button("Cancel") { confirmCancel = true }
                .font(.body.weight(.medium))
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.ultraThinMaterial, in: Capsule())

            Spacer()

            if visit.isRescanning { rescanPill } else { recordingPill }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    private var rescanPill: some View {
        Label(
            visit.rescanKeepsConversation ? "Re-scanning · conversation kept" : "Re-scanning room",
            systemImage: "arrow.clockwise"
        )
        .font(.subheadline.weight(.semibold))
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: Capsule())
        .accessibilityLabel("Re-scanning the room")
    }

    private var scanHint: some View {
        Label("Walk the whole room — keep every wall in view", systemImage: "figure.walk.motion")
            .font(.footnote.weight(.medium))
            .padding(.horizontal, BPSpacing.l)
            .padding(.vertical, BPSpacing.s + 1)
            .background(.ultraThinMaterial, in: Capsule())
            .padding(.top, BPSpacing.s)
            .transition(.opacity)
            .accessibilityLabel("Tip: walk the whole room and keep every wall in view")
    }

    private var recordingPill: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            HStack(spacing: 6) {
                Circle()
                    .fill(.red)
                    .frame(width: 8, height: 8)
                    .opacity(Int(context.date.timeIntervalSinceReferenceDate) % 2 == 0 ? 1 : 0.35)
                    .animation(.easeInOut(duration: 0.4), value: context.date)
                if let start = visit.scanStartedAt {
                    Text(Format.elapsed(since: start, now: context.date))
                        .font(.subheadline.weight(.semibold).monospacedDigit())
                }
                Image(systemName: "mic.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial, in: Capsule())
        }
        .accessibilityLabel("Recording audio")
    }

    private var finishButton: some View {
        Button {
            visit.finishVisit()
        } label: {
            Label("Finish Visit", systemImage: "checkmark")
                .font(.title3.weight(.bold))
                .frame(maxWidth: .infinity, minHeight: 58)
        }
        .buttonStyle(.borderedProminent)
        .tint(.yellow)
        .foregroundStyle(.black)
        .padding(.horizontal, 20)
        .padding(.bottom, 12)
    }
}
