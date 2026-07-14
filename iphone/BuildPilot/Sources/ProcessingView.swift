import SwiftUI
import UIKit

/// The wait screen after Finish Visit: a calm, honest checklist of what the
/// system is doing. Three steps, exactly matching what actually happens.
/// The phone may be lying on the kitchen table — keep it awake so the
/// upload is never killed by the device sleeping mid-coffee.
struct ProcessingView: View {
    let stage: VisitController.ProcessingStage
    @State private var startedAt = Date()

    private var isRevision: Bool { stage == .updatingQuote }

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            Text(isRevision ? "Updating your quotation…" : "Drafting Your Estimate")
                .font(.title2.bold())
                .padding(.bottom, 28)

            VStack(spacing: 0) {
                if isRevision {
                    StepRow(title: "Change request captured", symbol: "waveform", state: .done)
                    Divider().padding(.leading, 52)
                    StepRow(title: "Merging changes and re-pricing", symbol: "arrow.triangle.2.circlepath", state: .active)
                    Divider().padding(.leading, 52)
                    StepRow(title: "Refreshing the visualization", symbol: "photo", state: .pending)
                } else {
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

            // Honest, indeterminate progress: no fake percentage, but the
            // painter can see it's still working (and that a longer visit
            // simply takes longer) rather than staring at a frozen screen.
            TimelineView(.periodic(from: startedAt, by: 1)) { context in
                let seconds = max(0, Int(context.date.timeIntervalSince(startedAt)))
                VStack(spacing: 6) {
                    Text(Self.elapsed(seconds))
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(.secondary)
                    if seconds >= 40 {
                        Text("Longer visits take a little more time — keep the app open.")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 40)
                            .transition(.opacity)
                    }
                }
                .padding(.top, 14)
            }

            Spacer()
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemGroupedBackground))
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
    }

    private static func elapsed(_ seconds: Int) -> String {
        String(format: "%d:%02d", seconds / 60, seconds % 60)
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
                    .foregroundStyle(.yellow)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .accessibilityElement(children: .combine)
    }
}
