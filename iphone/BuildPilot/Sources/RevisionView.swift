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
        RecordingIndicator()
    }
}

/// Shared "● Recording" pill, used by both the live and reopened voice flows.
struct RecordingIndicator: View {
    var body: some View {
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

/// "Make Changes" for a REOPENED historical visit. Same speak-naturally UX as
/// the live flow, but it applies in place through the controller's
/// `applyHistoricalRevision` (same `/revise` pipeline, same session_id, no
/// duplicate) and dismisses — no phase change. Presented as a sheet from the
/// reopened estimate screen; the screen refreshes itself from history.
struct HistoricalRevisionView: View {
    let record: VisitRecord
    @ObservedObject var visit: VisitController
    let onClose: () -> Void

    enum Stage: Equatable {
        case starting          // requesting mic + starting the recorder
        case recording
        case processing        // transcribe → merge → re-estimate on the backend
        case done([String])    // applied; shows what changed
        case failed(String)    // carries the specific, safe reason to show
    }

    @State private var stage: Stage = .starting

    private static let micUnavailable =
        "Recording is unavailable. Allow microphone access in iPhone Settings, then try again."

    var body: some View {
        VStack(spacing: 0) {
            switch stage {
            case .starting, .recording: recordingBody
            case .processing: processingBody
            case let .done(changes): doneBody(changes)
            case let .failed(message): failedBody(message)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemGroupedBackground))
        .interactiveDismissDisabled(stage == .processing)
        .task {
            guard stage == .starting else { return }
            stage = await visit.beginHistoricalRevision() ? .recording : .failed(Self.micUnavailable)
        }
        .onDisappear {
            // Swiped away before applying → discard; never leave the mic on.
            if stage == .recording || stage == .starting {
                visit.cancelHistoricalRevision()
            }
        }
    }

    private var recordingBody: some View {
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
            RecordingIndicator()
                .padding(.top, 28)
            Spacer()
            VStack(spacing: 10) {
                Button {
                    Task {
                        stage = .processing
                        let outcome = await visit.applyHistoricalRevision(record: record)
                        if case let .success(changes) = outcome {
                            stage = .done(changes)
                        } else {
                            stage = .failed(outcome.failureMessage ?? Self.micUnavailable)
                        }
                    }
                } label: {
                    Label("Done — Update the Quote", systemImage: "checkmark")
                        .font(.title3.weight(.bold))
                        .frame(maxWidth: .infinity, minHeight: 58)
                }
                .buttonStyle(.borderedProminent)
                .tint(.yellow)
                .foregroundStyle(.black)
                .disabled(stage != .recording)

                Button("Cancel") {
                    visit.cancelHistoricalRevision()
                    onClose()
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(minHeight: 40)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 12)
        }
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
    }

    private var processingBody: some View {
        VStack(spacing: 16) {
            Spacer()
            ProgressView().controlSize(.large)
            Text("Updating the quote…")
                .font(.headline)
            Text("Applying your changes and re-pricing.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
        }
    }

    private func doneBody(_ changes: [String]) -> some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.green)
            Text("Quote Updated")
                .font(.title2.bold())
            if changes.isEmpty {
                Text("No changes were detected in what you said.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(changes, id: \.self) { change in
                        Label(change, systemImage: "arrow.right.circle")
                            .font(.subheadline)
                    }
                }
                .padding(.horizontal, 32)
            }
            Spacer()
            Button {
                onClose()
            } label: {
                Text("Done")
                    .font(.title3.weight(.bold))
                    .frame(maxWidth: .infinity, minHeight: 54)
            }
            .buttonStyle(.borderedProminent)
            .tint(.yellow)
            .foregroundStyle(.black)
            .padding(.horizontal, 24)
            .padding(.bottom, 12)
        }
    }

    private func failedBody(_ message: String) -> some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 44))
                .foregroundStyle(.orange)
            Text("Couldn't Update the Quote")
                .font(.title2.bold())
                .multilineTextAlignment(.center)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Spacer()
            VStack(spacing: 10) {
                Button {
                    // Re-request the mic and record again.
                    Task { stage = await visit.beginHistoricalRevision() ? .recording : .failed(Self.micUnavailable) }
                } label: {
                    Label("Try Again", systemImage: "arrow.clockwise")
                        .font(.title3.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 54)
                }
                .buttonStyle(.borderedProminent)
                .tint(.yellow)
                .foregroundStyle(.black)
                Button("Close") { onClose() }
                    .font(.headline)
                    .frame(minHeight: 44)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 12)
        }
    }
}
