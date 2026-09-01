import Foundation
import OSLog
import RoomPlan
import SwiftUI

/// Unified logging for field diagnostics — filter in Console.app with
/// subsystem "com.buildpilot.app". Invisible to the painter.
let visitLog = Logger(subsystem: "com.buildpilot.app", category: "visit")

/// The outcome of applying a spoken change to a reopened visit. Carries a
/// specific, safe reason so the sheet can tell the painter what actually went
/// wrong (the generic "couldn't update" hides real problems like a session the
/// server no longer has). `failureMessage` is nil only on success.
enum HistoricalRevisionOutcome: Equatable {
    case success([String])
    case recordingUnavailable   // no usable audio was captured
    case serverUnreachable      // backend couldn't be located/reached
    case visitNotFound          // 404 — the server no longer has this session
    case couldNotTranscribe     // 422 — no speech / transcription failed
    case failed                 // anything else

    var failureMessage: String? {
        switch self {
        case .success:
            return nil
        case .recordingUnavailable:
            return "The recording didn't capture any audio. Tap Try Again and speak once recording starts."
        case .serverUnreachable:
            return "Your backend couldn't be reached. Check your connection and try again."
        case .visitNotFound:
            return "This visit's details are no longer on the server, so it can't be edited here. The saved quote on this phone is unchanged."
        case .couldNotTranscribe:
            return "That change couldn't be understood. Speak clearly and try again."
        case .failed:
            return "The quote couldn't be updated. Your original quote is unchanged."
        }
    }
}

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
        case updatingQuote // customer revision being merged and re-priced

        static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    enum Phase {
        case idle
        case connecting // preflight before scanning starts
        case scanning
        case revising(SessionResponse) // recording the customer's change request
        case scanReview(WallLoopStatus) // wall loop open: rescan or proceed flagged
        case processing(ProcessingStage)
        case done(SessionResponse)
        case failed(message: String, canRetry: Bool)

        var isActiveVisit: Bool {
            if case .idle = self { return false }
            return true
        }
    }

    @Published var phase: Phase = .idle
    /// The pre-scan customer form is showing.
    @Published var draftingNewVisit = false
    /// True once the painter has done the scope read-back with the customer
    /// and moved on to the price. Reset for every new visit.
    @Published var readbackConfirmed = false
    /// True while the AI "proposed result" render is being generated.
    @Published var visualizationPending = false
    /// Set when the "proposed result" render couldn't be created; the estimate
    /// screen shows it with a Retry action instead of a spinner that silently
    /// vanishes. Nil when a render is pending or succeeded.
    @Published var renderError: String?
    /// What changed in the most recent revision, for the change-summary card.
    @Published var lastChanges: [String] = []
    @AppStorage("backendURL") var backendURLString = ""

    let roomCapture = RoomCaptureController()
    let history = VisitHistoryStore()
    /// The contractor's editable defaults — the pricing every new visit is
    /// built from, and the identity frozen onto each quote.
    let settings = ContractorSettingsStore()
    private let audioRecorder = AudioRecorder()

    private(set) var visitName = ""
    private(set) var scanStartedAt: Date?
    private(set) var pendingCustomer: CustomerInfo?
    private var pendingBundle: (roomJSON: Data, audioFile: URL?, poses: Data?)?
    /// The last render target, so a failed visualization can be retried.
    private var lastRenderTarget: (sessionID: String, backendURL: URL)?

    // Geometry-only rescan (Option B): recapture the room while keeping the
    // original conversation. The current quote is preserved and restored on
    // cancel; on success the new estimate replaces it in place.
    /// True while a rescan is in progress (drives the capture screen indicator).
    @Published private(set) var isRescanning = false
    /// Capture-closure state machine (pure logic, unit-tested). Guidance
    /// only: the backend recomputes its own completeness verdict from the
    /// same verbatim scan JSON.
    private(set) var guidedCapture = GuidedCaptureFlow()
    /// The scan's wall footprints, kept for the review screen's room sketch.
    private(set) var scanReviewFootprints: [WallFootprint] = []
    /// The audio from the last completed capture, reused by a rescan so the
    /// painter never loses the conversation (unique temp file, not overwritten).
    private var lastAudioFile: URL?
    /// When the painter confirmed the customer's recording consent —
    /// uploaded with the visit as evidence the consent step happened.
    private var recordingConsentAt: Date?
    private var rescanReuseAudio = false
    private var rescanReturnSession: SessionResponse?
    /// The capture screen tells the painter the conversation is being kept.
    var rescanKeepsConversation: Bool { isRescanning && rescanReuseAudio }

    var deviceSupported: Bool { RoomCaptureController.isSupported }

    // MARK: - visit lifecycle

    func startVisit(customer: CustomerInfo, recordingConsentAt: Date? = nil) async {
        pendingCustomer = customer
        self.recordingConsentAt = recordingConsentAt
        draftingNewVisit = false
        await startVisit()
    }

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
        // The visit clock: camera poses are timestamped against the moment
        // audio started, so spoken words and gaze line up on the backend.
        let audioStarted = Date()

        visitName = Self.visitName(for: pendingCustomer)
        scanStartedAt = audioStarted
        pendingBundle = nil
        readbackConfirmed = false
        roomCapture.start(clockReference: audioStarted)
        visitLog.info("Scanning started (backend: \(backendURL.absoluteString))")
        phase = .scanning
    }

    func finishVisit() {
        guard case .scanning = phase else { return }
        phase = .processing(.finalizingScan)
        let rescan = isRescanning
        let audioFile: URL?
        if rescan && rescanReuseAudio {
            audioFile = lastAudioFile // reuse the original conversation verbatim
        } else {
            audioFile = audioRecorder.stop()
            if let audioFile { lastAudioFile = audioFile }
        }

        roomCapture.onFinalResult = { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                switch result {
                case .success(let roomJSON):
                    // Skip poses on a rescan — new poses can't align with the
                    // reused audio's timeline, so gaze would mis-resolve.
                    let poses = rescan ? nil : self.roomCapture.posesJSON()
                    visitLog.info("Scan finalized: \(roomJSON.count) bytes room JSON, audio: \(audioFile != nil), poses: \(poses?.count ?? 0) bytes, rescan: \(rescan)")
                    self.pendingBundle = (roomJSON, audioFile, poses)
                    // Wall-loop gate: an open loop gets a review screen with
                    // the located gaps before anything is uploaded. Closed
                    // (or unassessable) proceeds exactly as before.
                    let assessment = Self.wallLoopAssessment(fromRoomJSON: roomJSON)
                    let status = assessment.status
                    self.scanReviewFootprints = assessment.footprints
                    self.guidedCapture.scanEnded(status)
                    if case .open(let ends, let walls) = status {
                        visitLog.info("Wall loop open: \(ends.count) gap(s) across \(walls) wall(s) — showing scan review")
                        self.phase = .scanReview(status)
                    } else {
                        await self.uploadPendingBundle()
                    }
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

    /// Decode the encoded CapturedRoom and assess the ground-plane wall loop.
    /// Falls back to .noWalls (no gate) when the JSON does not decode — the
    /// backend is the authority and will fail or flag the scan itself.
    static func wallLoopAssessment(
        fromRoomJSON data: Data
    ) -> (status: WallLoopStatus, footprints: [WallFootprint]) {
        guard let room = try? JSONDecoder().decode(CapturedRoom.self, from: data) else {
            return (.noWalls, [])
        }
        let footprints = WallLoop.footprints(
            transforms: room.walls.map(\.transform),
            dimensions: room.walls.map(\.dimensions)
        )
        return (WallLoop.assess(footprints), footprints)
    }

    /// Scan review: proceed with the open loop. The backend will measure it
    /// incomplete and the estimate will not be quotable until verified —
    /// allowed, never silent (Decision 34).
    func useScanAnyway() {
        guard case .scanReview = phase else { return }
        visitLog.info("Scan review: proceeding with open wall loop — backend will flag it")
        Task { await uploadPendingBundle() }
    }

    /// Scan review: walk the room again to close the loop. The conversation
    /// audio (already stopped by Finish) is kept verbatim; poses are skipped
    /// on upload, same as a post-upload rescan.
    func scanTheGaps() {
        guard case .scanReview = phase, guidedCapture.rescan() else { return }
        if let audio = pendingBundle?.audioFile { lastAudioFile = audio }
        rescanReuseAudio = lastAudioFile != nil
        isRescanning = true
        pendingBundle = nil
        scanStartedAt = Date()
        roomCapture.start(clockReference: Date())
        visitLog.info("Scan review: re-scanning to close the loop (rescan #\(self.guidedCapture.rescanCount))")
        phase = .scanning
    }

    /// Whether cancelling a rescan has a quote to return to (a gap-rescan
    /// before first upload does not — cancelling discards the visit).
    var canReturnToQuote: Bool { rescanReturnSession != nil }

    /// Re-capture the room geometry for the current visit, keeping the original
    /// conversation and requirements. The existing quote is preserved and shown
    /// again if the rescan is cancelled; on success the new estimate replaces it.
    func rescan() async {
        guard case .done(let current) = phase, deviceSupported else { return }
        phase = .connecting
        guard let backendURL = await locateAndRememberBackend(),
              await HTTPBackendClient(baseURL: backendURL).isReachable() else {
            visitLog.error("Rescan aborted: backend unreachable — keeping current quote")
            phase = .done(current) // never lose the existing quote
            return
        }

        // Reuse the original audio (and therefore the conversation) when we
        // still have it; only record fresh if the visit never had audio.
        let haveAudio = lastAudioFile.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
        rescanReuseAudio = haveAudio
        if !haveAudio {
            guard await audioRecorder.requestPermission() else { phase = .done(current); return }
            do { try audioRecorder.start() } catch { phase = .done(current); return }
        }

        rescanReturnSession = current
        isRescanning = true
        scanStartedAt = Date()
        pendingBundle = nil
        roomCapture.start(clockReference: Date())
        visitLog.info("Rescan started (reuse audio: \(haveAudio))")
        phase = .scanning
    }

    /// Abandons the current scan. A rescan returns to the existing quote
    /// (nothing is lost); a first scan discards audio and returns home.
    func cancelVisit() {
        roomCapture.onFinalResult = nil
        roomCapture.stop()
        if isRescanning {
            if !rescanReuseAudio { _ = audioRecorder.stop() }
            let ret = rescanReturnSession
            isRescanning = false
            rescanReuseAudio = false
            rescanReturnSession = nil
            scanStartedAt = nil
            readbackConfirmed = true
            phase = ret.map { .done($0) } ?? .idle
            return
        }
        _ = audioRecorder.stop()
        scanStartedAt = nil
        phase = .idle
    }

    // MARK: - customer revision ("Make Changes")

    /// The customer wants changes: return to listening mode.
    func startRevision() async {
        guard case .done(let session) = phase else { return }
        guard await audioRecorder.requestPermission() else { return }
        do {
            try audioRecorder.start()
            lastChanges = []
            visitLog.info("Revision recording started")
            phase = .revising(session)
        } catch {
            visitLog.error("Revision recording failed to start: \(error.localizedDescription)")
        }
    }

    func cancelRevision(returnTo session: SessionResponse) {
        _ = audioRecorder.stop()
        phase = .done(session)
    }

    func finishRevision(for session: SessionResponse) async {
        guard let audioFile = audioRecorder.stop() else {
            phase = .done(session)
            return
        }
        phase = .processing(.updatingQuote)
        guard let url = await BackendLocator.locate(configuredURLString: backendURLString) else {
            phase = .failed(message: "Your Mac couldn't be reached to update the quote. The original quote is unchanged.", canRetry: false)
            return
        }
        do {
            let result = try await HTTPBackendClient(baseURL: url)
                .revise(sessionID: session.sessionId, audioFile: audioFile)
            visitLog.info("Revision v\(result.version): \(result.changes.joined(separator: "; "))")
            lastChanges = result.changes
            history.add(name: visitName, session: result.session, customer: pendingCustomer)
            readbackConfirmed = true // straight back to the quote
            phase = .done(result.session)
            // The old renders no longer match the revised quote — regenerate
            // them in the background, exactly like after the original scan.
            if result.renderRequired {
                requestRenders(sessionID: session.sessionId, backendURL: url)
            }
        } catch {
            visitLog.error("Revision failed: \(error.localizedDescription)")
            phase = .failed(
                message: "The changes couldn't be applied — the original quote is unchanged. \(Self.friendlyUploadError(error))",
                canRetry: false
            )
        }
    }

    /// Re-sends the captured bundle after a failed upload — the scan and
    /// audio are never lost to a network problem.
    func retryUpload() async {
        guard pendingBundle != nil else { return }
        await uploadPendingBundle()
    }

    /// Applies manual plan edits (Edit Plan) to the current visit in place: a
    /// deterministic backend re-estimate, history updated under the SAME id
    /// (no duplicate), outputs flagged stale for explicit regeneration. A nil
    /// payload (cancel / no changes) is a no-op.
    func savePlanEdit(payload: PlanEditPayload?, pdfStale: Bool, visualizationStale: Bool) async {
        guard case .done(let current) = phase, let payload else { return }
        guard let url = await BackendLocator.locate(configuredURLString: backendURLString) else { return }
        do {
            let result = try await HTTPBackendClient(baseURL: url)
                .reestimate(sessionID: current.sessionId, edit: payload)
            history.add(name: visitName, session: result.session, customer: pendingCustomer)
            history.markStale(pdf: pdfStale, visualization: visualizationStale, for: current.sessionId)
            lastChanges = result.changes
            readbackConfirmed = true
            phase = .done(result.session) // refresh the estimate with the new numbers
            visitLog.info("Plan edited: \(result.changes.joined(separator: "; "))")
        } catch {
            visitLog.error("Plan edit failed (quote unchanged): \(error.localizedDescription)")
        }
    }

    /// Edits a reopened historical visit in place: a deterministic re-estimate on
    /// the SAME session_id, saved under the SAME history entry (customer, photos,
    /// confirmation state and version history all preserved — no new visit).
    /// No phase change: the reopened screen refreshes because EstimateView reads
    /// the session from history.
    func editHistoricalPlan(record: VisitRecord, payload: PlanEditPayload?, pdfStale: Bool, visualizationStale: Bool) async {
        guard let payload else { return }
        guard let url = await BackendLocator.locate(configuredURLString: backendURLString) else { return }
        do {
            let result = try await HTTPBackendClient(baseURL: url)
                .reestimate(sessionID: record.id, edit: payload)
            // customer nil → carries the existing record's customer/photos/state.
            history.add(name: record.name, session: result.session)
            history.markStale(pdf: pdfStale, visualization: visualizationStale, for: record.id)
            visitLog.info("Historical plan edited (\(record.id))")
        } catch {
            visitLog.error("Historical plan edit failed (unchanged): \(error.localizedDescription)")
        }
    }

    // MARK: - reopened-visit voice editing ("Make Changes" on a historical visit)

    /// Starts recording a spoken change for a reopened historical visit. Same
    /// mic capture as the live flow, but deliberately NO phase change — the
    /// reopened screen stays put and refreshes in place, exactly like
    /// `editHistoricalPlan`. Presentation is the reopened view's own sheet.
    func beginHistoricalRevision() async -> Bool {
        guard await audioRecorder.requestPermission() else { return false }
        do {
            try audioRecorder.start()
            visitLog.info("Historical revision recording started")
            return true
        } catch {
            visitLog.error("Historical revision recording failed to start: \(error.localizedDescription)")
            return false
        }
    }

    /// Discards an in-progress historical-revision recording (Cancel, or the
    /// sheet swiped away). Never leaves the mic running; the quote is untouched.
    func cancelHistoricalRevision() {
        _ = audioRecorder.stop()
    }

    /// Applies the spoken change to a reopened visit through the SAME `/revise`
    /// pipeline the live flow uses — transcribe → LLM-merge → deterministic
    /// re-estimate, versioned server-side (original transcript preserved, the
    /// new instruction appended). Updates the SAME session_id / history entry in
    /// place (customer, photos, business snapshot and prior versions all carry
    /// over — no duplicate visit), then marks outputs stale per the existing
    /// rules WITHOUT auto-regenerating anything. Returns the change summary on
    /// success, or a specific failure the sheet surfaces to the painter. Emits
    /// safe diagnostics (session id, file existence/size, request URL, HTTP
    /// status, error body) — never audio contents, tokens, or transcript text.
    func applyHistoricalRevision(record: VisitRecord) async -> HistoricalRevisionOutcome {
        guard let audioFile = audioRecorder.stop() else {
            visitLog.error("Historical revision: recorder produced no audio file (session=\(record.id))")
            return .recordingUnavailable
        }
        // Confirm the recording is a real, non-empty file before uploading —
        // an empty upload would fail transcription with a confusing 422.
        let exists = FileManager.default.fileExists(atPath: audioFile.path)
        let bytes = (try? FileManager.default.attributesOfItem(atPath: audioFile.path)[.size]) as? Int ?? 0
        visitLog.info("Historical revision: session=\(record.id) fileExists=\(exists) bytes=\(bytes) ext=\(audioFile.pathExtension)")
        guard exists, bytes > 0 else {
            visitLog.error("Historical revision: empty/missing audio (exists=\(exists) bytes=\(bytes))")
            return .recordingUnavailable
        }
        guard let url = await BackendLocator.locate(configuredURLString: backendURLString) else {
            visitLog.error("Historical revision: no backend URL available")
            return .serverUnreachable
        }
        visitLog.info("Historical revision: POST \(url.absoluteString)/sessions/\(record.id)/revise")
        do {
            let result = try await HTTPBackendClient(baseURL: url)
                .revise(sessionID: record.id, audioFile: audioFile)
            // customer nil → the existing record's customer/photos/snapshot/state
            // carry over; only the session content is replaced (same id).
            history.add(name: record.name, session: result.session)
            // A voice change is quote-relevant → the PDF is stale; renders are
            // stale only when the backend says so. Never auto-regenerate.
            history.markStale(pdf: true, visualization: result.renderRequired, for: record.id)
            lastChanges = result.changes
            visitLog.info("Historical revision applied (\(record.id)): \(result.changes.count) change(s)")
            return .success(result.changes)
        } catch HTTPBackendClient.UploadError.badStatus(let code, let body) {
            visitLog.error("Historical revision failed: HTTP \(code) body=\(body.prefix(160))")
            switch code {
            case 404: return .visitNotFound
            case 422: return .couldNotTranscribe
            default: return .failed
            }
        } catch let urlError as URLError {
            visitLog.error("Historical revision transport failure: URLError \(urlError.code.rawValue)")
            return .serverUnreachable
        } catch {
            visitLog.error("Historical revision failed: \(error.localizedDescription)")
            return .failed
        }
    }

    func reset() {
        scanStartedAt = nil
        isRescanning = false
        rescanReuseAudio = false
        rescanReturnSession = nil
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

    /// The consent record uploaded with every visit (string values only —
    /// the backend namespaces them client_* into raw_metadata).
    private func consentMetadata() -> [String: String] {
        var metadata = ["recording_consent": recordingConsentAt != nil ? "true" : "false"]
        if let at = recordingConsentAt {
            metadata["recording_consent_at"] = ISO8601DateFormatter().string(from: at)
        }
        return metadata
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
                .submitVisit(roomScan: bundle.roomJSON, audioFile: bundle.audioFile, poses: bundle.poses,
                             companyProfile: settings.settings.companyProfile(),
                             clientMetadata: consentMetadata())
            visitLog.info("Upload + pipeline finished in \(Date().timeIntervalSince(uploadStarted), format: .fixed(precision: 1))s → \(session.status) (\(session.sessionId))")
            if session.status == "completed" {
                pendingBundle = nil
                if isRescanning {
                    // Replace the current visit in place; the conversation is
                    // unchanged, so go straight to the updated quote.
                    if let old = rescanReturnSession { history.remove(id: old.sessionId) }
                    isRescanning = false
                    rescanReuseAudio = false
                    rescanReturnSession = nil
                    readbackConfirmed = true
                }
                // Freeze the business identity onto this new visit at creation.
                let snapshot = BusinessSnapshot.capture(from: settings.settings, visitID: session.sessionId)
                history.add(name: visitName, session: session, customer: pendingCustomer, business: snapshot)
                phase = .done(session)
                finalizeVisitMedia(sessionID: session.sessionId, backendURL: url)
            } else {
                pendingBundle = nil // the Mac rejected the scan; retrying won't help
                isRescanning = false
                rescanReuseAudio = false
                rescanReturnSession = nil
                phase = .failed(
                    message: Self.scanGuidance(from: session),
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
        let frames = roomCapture.bestBeforePhotos() // best-first, with capture times
        visitLog.info("Auto-captured \(frames.count) Before photos from the scan")

        var savedPhotos: [(photo: VisitPhoto, t: Double)] = []
        for frame in frames {
            if let photo = PhotoStore.save(frame.image, visitID: sessionID, kind: .before) {
                history.addPhoto(photo, to: sessionID)
                savedPhotos.append((photo, frame.t)) // record order = best-first (drives app + PDF)
            }
        }

        Task { [weak self] in
            let client = HTTPBackendClient(baseURL: backendURL)
            // 1. Archive the Before photos with their capture times so the
            //    backend can match each to a camera pose and pick the frame
            //    that shows the painted wall most completely. Reversed: the
            //    BEST frame lands last — the fallback when no poses exist.
            for entry in savedPhotos.reversed() {
                guard let jpeg = PhotoStore.jpegData(entry.photo, visitID: sessionID) else { continue }
                do {
                    try await client.uploadPhoto(
                        sessionID: sessionID, kind: "before", jpeg: jpeg, t: entry.t
                    )
                } catch {
                    visitLog.warning("Before-photo archive failed: \(error.localizedDescription)")
                }
            }
            // 2. Request the AI stage renders.
            self?.requestRenders(sessionID: sessionID, backendURL: backendURL)
        }
    }

    /// Requests the AI stage renders (finished result first — it's the one
    /// the customer is waiting for — then the preparation view) and saves
    /// them as visit photos. Best-effort: the estimate is never delayed and
    /// a failed render simply leaves the previous images in place.
    private func requestRenders(sessionID: String, backendURL: URL) {
        lastRenderTarget = (sessionID, backendURL)
        renderError = nil
        visualizationPending = true
        Task { [weak self] in
            let client = HTTPBackendClient(baseURL: backendURL)
            let stages: [(String, PhotoKind)] = [
                ("finished", .visualization),
                ("preparation", .preparation),
            ]
            for (stage, kind) in stages {
                // The hosted image model can transiently 503 (cold start /
                // rate limit) or time out — the biggest cause of the After
                // appearing "inconsistently". Retry the hero render on a
                // transient failure before giving up. Deterministic gates
                // (409: no Before, or no conversation) are NOT retried.
                let maxAttempts = stage == "finished" ? 3 : 1
                var lastError: Error?
                for attempt in 1 ... maxAttempts {
                    do {
                        let jpeg = try await client.requestVisualization(sessionID: sessionID, stage: stage)
                        guard let self else { return }
                        lastError = nil
                        if let image = UIImage(data: jpeg),
                           let photo = PhotoStore.save(image, visitID: sessionID, kind: kind) {
                            self.history.addPhoto(photo, to: sessionID)
                            visitLog.info("Render saved: \(stage) (\(jpeg.count / 1024) kB, attempt \(attempt))")
                        } else {
                            visitLog.error("Render \(stage): received \(jpeg.count) bytes but could not decode/save image")
                        }
                        break
                    } catch {
                        lastError = error
                        visitLog.warning("Render \(stage) attempt \(attempt)/\(maxAttempts) failed — \(Self.renderErrorDetail(error))")
                        if attempt < maxAttempts, Self.isTransientRenderError(error) {
                            try? await Task.sleep(for: .seconds(3))
                            continue
                        }
                        break
                    }
                }
                // The hero image is done (or exhausted retries) — stop the
                // spinner and surface any final failure; the preparation view
                // arrives quietly when ready.
                if stage == "finished" {
                    self?.renderError = lastError.map { Self.friendlyRenderError($0) }
                    self?.visualizationPending = false
                }
            }
        }
    }

    /// Transient render failures worth retrying: a 5xx from the image model
    /// (503 cold start / rate limit) or a dropped/timed-out connection. A 409
    /// (deterministic precondition) is never transient.
    private static func isTransientRenderError(_ error: Error) -> Bool {
        if let uploadError = error as? HTTPBackendClient.UploadError,
           case let .badStatus(code, _) = uploadError {
            return (500 ... 599).contains(code)
        }
        if let urlError = error as? URLError {
            return [.timedOut, .networkConnectionLost, .cannotConnectToHost].contains(urlError.code)
        }
        return false
    }

    /// Precise diagnostic string for the logs — the exact HTTP status/body so
    /// the failing gate (401 / 409 / 503 …) is never a guess.
    private static func renderErrorDetail(_ error: Error) -> String {
        if let uploadError = error as? HTTPBackendClient.UploadError,
           case let .badStatus(code, body) = uploadError {
            return "HTTP \(code): \(body.prefix(160))"
        }
        return error.localizedDescription
    }

    /// Re-requests the AI renders after a failure (from the estimate screen).
    func retryRenders() {
        guard let target = lastRenderTarget else { return }
        requestRenders(sessionID: target.sessionID, backendURL: target.backendURL)
    }

    /// Specific, actionable guidance derived from the backend's measurement
    /// error — the painter should never have to guess what went wrong.
    private static func scanGuidance(from session: SessionResponse) -> String {
        let detail = session.rawMetadata?["error"] ?? ""
        if detail.localizedCaseInsensitiveContains("no walls") {
            return "The scan didn't capture any walls.\n\nWalk the room slowly and point the camera at each wall until it highlights on screen, then finish the visit."
        }
        if detail.localizedCaseInsensitiveContains("room scan") {
            return "The room scan file couldn't be read. Scan the room again from the start."
        }
        return "The scan couldn't be measured. Walk the full room again — every wall, corner to corner — before finishing."
    }

    private static func friendlyUploadError(_ error: Error) -> String {
        let base = "The visit is saved on this iPhone — nothing is lost."
        // A server that answered with an HTTP error tells us more than a
        // transport failure — distinguish "not authorized" and "server fault"
        // from "couldn't reach it", so the painter knows whether retrying helps.
        if let uploadError = error as? HTTPBackendClient.UploadError,
           case let .badStatus(code, _) = uploadError {
            switch code {
            case 401, 403:
                return "This iPhone isn't authorized to reach the server. \(base)\n\nThe app likely needs an update with the current access key — retrying won't fix it."
            case 500...599:
                return "The server hit a problem and couldn't finish. \(base)\n\nTry again in a moment."
            default:
                return "The server couldn't process the visit (error \(code)). \(base)\n\nTry again in a moment."
            }
        }
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

    /// Painter-facing reason a "proposed result" render failed. Presentation
    /// only — the quote itself is never affected by a missing visualization.
    private static func friendlyRenderError(_ error: Error) -> String {
        if let uploadError = error as? HTTPBackendClient.UploadError,
           case let .badStatus(code, _) = uploadError {
            switch code {
            case 503:
                return "The preview service is temporarily unavailable. Your quote is unaffected — retry, or share the quote without the preview."
            case 409:
                return "A preview needs a Before photo and the recorded conversation. Your quote is unaffected."
            default:
                break
            }
        }
        return "The preview couldn't be created right now. Your quote is unaffected."
    }

    private static func visitName(for customer: CustomerInfo?) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "d MMM"
        let date = formatter.string(from: Date())
        if let name = customer?.name.trimmingCharacters(in: .whitespaces), !name.isEmpty {
            return "\(name) · \(date)"
        }
        return "Visit · \(date)"
    }
}
