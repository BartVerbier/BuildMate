import SwiftUI

/// The capture screen: Apple's native RoomPlan experience full-bleed, with
/// exactly two of our own controls — a live recording indicator and Finish.
struct CaptureVisitView: View {
    @ObservedObject var visit: VisitController
    @State private var confirmCancel = false

    var body: some View {
        ZStack {
            RoomCaptureViewRepresentable(controller: visit.roomCapture)
                .ignoresSafeArea()

            VStack {
                topBar
                Spacer()
                finishButton
            }
        }
        .statusBarHidden()
        .confirmationDialog(
            "Discard this visit?",
            isPresented: $confirmCancel,
            titleVisibility: .visible
        ) {
            Button("Discard Visit", role: .destructive) { visit.cancelVisit() }
            Button("Keep Scanning", role: .cancel) {}
        } message: {
            Text("The room scan and audio recording will be deleted.")
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

            recordingPill
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
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
