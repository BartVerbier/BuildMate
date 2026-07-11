import SwiftUI

/// Listening mode for customer changes: one question, one big stop button.
struct RevisionRecordingView: View {
    let session: SessionResponse
    @ObservedObject var visit: VisitController

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            Image(systemName: "waveform")
                .font(.system(size: 46))
                .foregroundStyle(.yellow)
                .symbolEffect(.variableColor.iterative, options: .repeating)
            Text("What would you like to change?")
                .font(.system(.title, design: .rounded).bold())
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
                .padding(.top, 18)
            Text("I'm listening — just describe the changes naturally.")
                .font(.body)
                .foregroundStyle(.secondary)
                .padding(.top, 6)

            recordingIndicator
                .padding(.top, 28)

            Spacer()

            VStack(spacing: 10) {
                Button {
                    Task { await visit.finishRevision(for: session) }
                } label: {
                    Label("Done — Update the Quote", systemImage: "checkmark")
                        .font(.title3.weight(.bold))
                        .frame(maxWidth: .infinity, minHeight: 58)
                }
                .buttonStyle(.borderedProminent)
                .tint(.yellow)
                .foregroundStyle(.black)

                Button("Cancel") {
                    visit.cancelRevision(returnTo: session)
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(minHeight: 40)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemGroupedBackground))
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
    }

    private var recordingIndicator: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            HStack(spacing: 8) {
                Circle()
                    .fill(.red)
                    .frame(width: 9, height: 9)
                    .opacity(Int(context.date.timeIntervalSinceReferenceDate) % 2 == 0 ? 1 : 0.3)
                Text("Recording")
                    .font(.subheadline.weight(.semibold))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial, in: Capsule())
        }
    }
}
