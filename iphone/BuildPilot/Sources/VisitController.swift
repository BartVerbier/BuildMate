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
    /// True while the AI "proposed result" render is being generated.
    @Published var visualizationPending = false
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
        guard let backendURL = await locateAndRememberBackend() else {
            visitLog.error("Start visit aborted: no backend found")
            phase = .failed(
                message: "Couldn't find your Mac on this Wi-Fi.\n\nMake sure the Mac is awake, on the same network, and running Build Pilot. Then try again — or pick your Mac in Settings (the gear on the Visits screen).",
                canRetry: false
            )
            return
        }
        guard await HTTPBackendClient(baseURL: backendURL).isReachable() else {
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

    /// Resolves the backend via BackendLocator (production URL → configured
    /// URL → local discovery) and remembers a discovered one in Settings.
    private func locateAndRememberBackend() async -> URL? {
        guard let url = await BackendLocator.locate(configuredURLString: backendURLString) else {
            return nil
        }
        if backendURLString.isEmpty {
            backendURLString = url.absoluteString
        }
        return url
    }

    private func uploadPendingBundle() async {
        guard let bundle = pendingBundle,
              let url = await BackendLocator.locate(configuredURLString: backendURLString) else {
            phase = .failed(message: "No Mac is configured. Pick your Mac in Settings and try again.", canRetry: false)
            return
        }
        phase = .processing(.drafting)
        let uploadStarted = Date()
        do {
            let session = try await HTTPBackendClient(baseURL: url)
                .submitVisit(roomScan: bundle.roomJSON, audioFile: bundle.audioFile)
            visitLog.info("Upload + pipeline finished in \(Date().timeIntervalSince(uploadStarted), format: .fixed(precision: 1))s → \(session.status) (\(session.sessionId))")
            if session.status == "completed" {
                pendingBundle = nil
                history.add(name: visitName, session: session)
                phase = .done(session)
                finalizeVisitMedia(sessionID: session.sessionId, backendURL: url)
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

    // MARK: - automatic visit media (Before photos + proposed-result render)

    /// After a successful visit: save the sharpest scan frames as Before
    /// photos, archive them, then request the AI visualization. All
    /// best-effort and in the background — the estimate is never delayed.
    private func finalizeVisitMedia(sessionID: String, backendURL: URL) {
        let frames = roomCapture.bestBeforePhotos()
        visitLog.info("Auto-captured \(frames.count) Before photos from the scan")

        var savedPhotos: [VisitPhoto] = []
        for image in frames {
            if let photo = PhotoStore.save(image, visitID: sessionID, kind: .before) {
                history.addPhoto(photo, to: sessionID)
                savedPhotos.append(photo)
            }
        }

        visualizationPending = true
        Task { [weak self] in
            let client = HTTPBackendClient(baseURL: backendURL)
            // 1. Archive the Before photos (the render needs one server-side).
            for photo in savedPhotos {
                guard let jpeg = PhotoStore.jpegData(photo, visitID: sessionID) else { continue }
                do {
                    try await client.uploadPhoto(sessionID: sessionID, kind: "before", jpeg: jpeg)
                } catch {
                    visitLog.warning("Before-photo archive failed: \(error.localizedDescription)")
                }
            }
            // 2. Request the proposed-result render.
            do {
                let jpeg = try await client.requestVisualization(sessionID: sessionID)
                await MainActor.run {
                    guard let self else { return }
                    if let image = UIImage(data: jpeg),
                       let photo = PhotoStore.save(image, visitID: sessionID, kind: .visualization) {
                        self.history.addPhoto(photo, to: sessionID)
                        visitLog.info("Visualization saved (\(jpeg.count / 1024) kB)")
                    }
                    self.visualizationPending = false
                }
            } catch {
                visitLog.warning("Visualization unavailable: \(error.localizedDescription)")
                await MainActor.run { self?.visualizationPending = false }
            }
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
