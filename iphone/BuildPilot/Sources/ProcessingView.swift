import SwiftUI

/// The wait screen after Finish Visit: a calm, honest checklist of what the
/// system is doing. Three steps, exactly matching what actually happens.
struct ProcessingView: View {
    let stage: VisitController.ProcessingStage

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            Text("Drafting Your Estimate")
                .font(.title2.bold())
                .padding(.bottom, 28)

            VStack(spacing: 0) {
                StepRow(
                    title: "Room scan",
                    symbol: "cube",
                    state: stage >= .drafting ? .done : .active
                )
                Divider().padding(.leading, 52)
                StepRow(
                    title: "Audio recording",
                    symbol: "waveform",
                    state: .done
                )
                Divider().padding(.leading, 52)
                StepRow(
                    title: "Drafting estimate on your Mac",
                    symbol: "desktopcomputer",
                    state: stage >= .drafting ? .active : .pending
                )
            }
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .padding(.horizontal, 20)

            Text("Transcription runs locally on your Mac — the conversation never goes to the cloud.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
                .padding(.top, 20)

            Spacer()
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemGroupedBackground))
    }
}

private struct StepRow: View {
    enum StepState { case pending, active, done }

    let title: String
    let symbol: String
    let state: StepState

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.body)
                .foregroundStyle(.secondary)
                .frame(width: 24)
                .accessibilityHidden(true)

            Text(title)
                .font(.body)
                .foregroundStyle(state == .pending ? .secondary : .primary)

            Spacer()

            switch state {
            case .pending:
                Image(systemName: "circle.dotted")
                    .foregroundStyle(.tertiary)
            case .active:
                ProgressView()
            case .done:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .accessibilityElement(children: .combine)
    }
}
