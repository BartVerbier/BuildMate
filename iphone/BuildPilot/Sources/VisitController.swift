import Foundation
import OSLog
import SwiftUI

/// Unified logging for field diagnostics — filter in Console.app with
/// subsystem "com.buildpilot.app". Invisible to the painter.
let visitLog = Logger(subsystem: "com.buildpilot.app", category: "visit")

/// The visit state machine: idle → scanning → processing → estimate/failed.
///
/// Reliability rules for real-world use:
/// - Never let a painter start scanning into a dead connection (preflight).
/// - Never lose a captured visit to a network blip (bundle kept, Try Again).
/// - Never show a technical error (all failures in painter language).
@MainActor
final class VisitController: ObservableObject {
    enum ProcessingStage: Int, Comparable {
        case finalizingScan
        case drafting // upload + Mac pipeline (one synchronous call)

        static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    enum Phase {
        case idle
        case connecting // preflight before scanning starts
        case scanning
        case processing(ProcessingStage)
        case done(SessionResponse)
        case failed(message: String, canRetry: Bool)

        var isActiveVisit: Bool {
            if case .idle = self { return false }
            return true
        }
    }

    @Published var phase: Phase = .idle
    /// True once the painter has done the scope read-back with the customer
    /// and moved on to the price. Reset for every new visit.
    @Published var readbackConfirmed = false
    @AppStorage("backendURL") var backendURLString = ""

    let roomCapture = RoomCaptureController()
    let history = VisitHistoryStore()
    private let audioRecorder = AudioRecorder()

    private(set) var visitName = ""
    private(set) var scanStartedAt: Date?
    private var pendingBundle: (roomJSON: Data, audioFile: URL?)?

    var deviceSupported: Bool { RoomCaptureController.isSupported }

    // MARK: - visit lifecycle

    func startVisit() async {
        guard deviceSupported else {
            phase = .failed(
                message: "This iPhone can't scan rooms — a Pro model with LiDAR is required.",
                canRetry: false
            )
            return
        }

        phase = .connecting
        visitLog.info("Start visit: locating backend (configured: \(!self.backendURLString.isEmpty))")
        guard let backendURL = await locateBackend() else {
            visitLog.error("Start visit aborted: no backend found")
            phase = .failed(
                message: "Couldn't find your Mac on this Wi-Fi.\n\nMake sure the Mac is awake, on the same network, and running Build Pilot. Then try again — or pick your Mac in Settings (the gear on the Visits screen).",
                canRetry: false
            )
            return
        }
        guard await Self.isReachable(backendURL) else {
            visitLog.error("Start visit aborted: \(backendURL.absoluteString) not answering /health")
            phase = .failed(
                message: "Your Mac was found but isn't answering.\n\nCheck that Build Pilot is running on it, then try again.",
                canRetry: false
            )
            return
        }

        guard await audioRecorder.requestPermission() else {
            phase = .failed(
                message: "Build Pilot needs the microphone to record the visit conversation.\n\nAllow it in iPhone Settings → Privacy → Microphone.",
                canRetry: false
            )
            return
        }
        do {
            try audioRecorder.start()
        } catch {
            phase = .failed(message: "Audio recording couldn't start. Close other apps using the microphone and try again.", canRetry: false)
            return
        }

        visitName = Self.defaultVisitName()
        scanStartedAt = Date()
        pendingBundle = nil
        readbackConfirmed = false
        roomCapture.start()
        visitLog.info("Scanning started (backend: \(backendURL.absoluteString))")
        phase = .scanning
    }

    func finishVisit() {
        guard case .scanning = phase else { return }
        phase = .processing(.finalizingScan)
        let audioFile = audioRecorder.stop()

        roomCapture.onFinalResult = { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                switch result {
                case .success(let roomJSON):
                    visitLog.info("Scan finalized: \(roomJSON.count) bytes room JSON, audio: \(audioFile != nil)")
                    self.pendingBundle = (roomJSON, audioFile)
                    await self.uploadPendingBundle()
                case .failure(let error):
                    visitLog.error("RoomPlan processing failed: \(error.localizedDescription)")
                    self.phase = .failed(
                        message: "The room scan couldn't be completed. Walk the room again, keeping every wall in view.",
                        canRetry: false
                    )
                }
            }
        }
        roomCapture.stop()
    }

    /// Abandons the visit: discards audio and scan, returns home.
    func cancelVisit() {
        roomCapture.onFinalResult = nil
        roomCapture.stop()
        _ = audioRecorder.stop()
        scanStartedAt = nil
        phase = .idle
    }

    /// Re-sends the captured bundle after a failed upload — the scan and
    /// audio are never lost to a network problem.
    func retryUpload() async {
        guard pendingBundle != nil else { return }
        await uploadPendingBundle()
    }

    func reset() {
        scanStartedAt = nil
        phase = .idle
    }

    // MARK: - backend

    /// Returns the configured backend if set; otherwise discovers one on the
    /// network (zero-config first run) and remembers it.
    private func locateBackend() async -> URL? {
        if let url = URL(string: backendURLString), !backendURLString.isEmpty {
            return url
        }
        if let discovered = await BackendDiscovery.quickFind() {
            backendURLString = discovered.absoluteString
            return discovered
        }
        return nil
    }

    static func isReachable(_ backendURL: URL) async -> Bool {
        var request = URLRequest(url: backendURL.appendingPathComponent("health"))
        request.timeoutInterval = 3
        guard let (_, response) = try? await URLSession.shared.data(for: request) else { return false }
        return (response as? HTTPURLResponse)?.statusCode == 200
    }

    private func uploadPendingBundle() async {
        guard let bundle = pendingBundle, let url = URL(string: backendURLString) else {
            phase = .failed(message: "No Mac is configured. Pick your Mac in Settings and try again.", canRetry: false)
            return
        }
        phase = .processing(.drafting)
        let uploadStarted = Date()
        do {
            let session = try await SessionUploader(backendURL: url)
                .upload(roomScan: bundle.roomJSON, audioFile: bundle.audioFile)
            visitLog.info("Upload + pipeline finished in \(Date().timeIntervalSince(uploadStarted), format: .fixed(precision: 1))s → \(session.status) (\(session.sessionId))")
            if session.status == "completed" {
                pendingBundle = nil
                history.add(name: visitName, session: session)
                phase = .done(session)
            } else {
                pendingBundle = nil // the Mac rejected the scan; retrying won't help
                phase = .failed(
                    message: "Your Mac couldn't measure this scan. Walk the room again, keeping every wall in view.",
                    canRetry: false
                )
            }
        } catch {
            visitLog.error("Upload failed after \(Date().timeIntervalSince(uploadStarted), format: .fixed(precision: 1))s: \(error.localizedDescription)")
            phase = .failed(message: Self.friendlyUploadError(error), canRetry: true)
        }
    }

    private static func friendlyUploadError(_ error: Error) -> String {
        let base = "The visit is saved on this iPhone — nothing is lost."
        guard let urlError = error as? URLError else {
            return "Sending to your Mac failed. \(base)\n\nTry again in a moment."
        }
        switch urlError.code {
        case .timedOut:
            return "Your Mac is taking too long to answer. \(base)\n\nCheck the Mac is awake, then try again."
        case .cannotConnectToHost, .cannotFindHost, .networkConnectionLost, .notConnectedToInternet:
            return "Your Mac couldn't be reached. \(base)\n\nCheck both devices are on the same Wi-Fi, then try again."
        default:
            return "Sending to your Mac failed. \(base)\n\nTry again in a moment."
        }
    }

    private static func defaultVisitName() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "d MMM, HH:mm"
        return "Visit — \(formatter.string(from: Date()))"
    }
}
