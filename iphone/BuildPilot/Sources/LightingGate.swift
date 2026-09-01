import ARKit
import Foundation

/// Pre-scan lighting survey: a self-contained ARSession that samples
/// `ARFrame.lightEstimate.ambientIntensity` while the estimator WALKS the
/// room BEFORE the RoomPlan capture starts — "let me just check the light
/// real quick". The gate verdict is driven by the WORST reading seen on
/// the walk: one dark corner is exactly what a single stationary sample
/// (and any average) would miss. The estimator ends the walk themselves
/// ("Done Checking"); the summary then gates Start Visit.
///
/// Deliberately standalone: it never touches RoomCaptureView or
/// RoomCaptureSession, and is fully torn down before either starts. The
/// during-scan lighting trigger (.turnOnLight) is a separate, later task.
///
/// Thresholds are PROVISIONAL, anchored only on Apple's "1000 lumens =
/// neutral lighting" — the multi-room test campaign tunes them. Keep them
/// here, named, so retuning is a one-line change.
enum LightThresholds {
    /// At or above this median: proceed silently.
    static let proceedMinLumens: Double = 500
    /// Below this median: hold — Start Scan stays disabled until the
    /// reading recovers. Between the two: warn but allow proceeding.
    static let holdBelowLumens: Double = 200
    /// Median window: long enough to ride out auto-exposure convergence
    /// and one-frame noise, short enough to react when a light turns on.
    static let medianWindowSeconds: TimeInterval = 2.5
    /// Warm-up bound: if no light sample arrives within this many seconds
    /// of start(), the gate declares itself unavailable and fails open —
    /// a dead session must neither hold Start hostage nor die silently.
    static let warmupTimeoutSeconds: TimeInterval = 4
}

/// TBD/PLACEHOLDER COPY — needs a copy pass. Tone target: routine and
/// brisk, not apologetic. Both warn and hold states show this same line;
/// hold additionally disables Start.
enum LightingGateCopy {
    static let moreLightNeeded =
        "More light needed to scan accurately — turn on lights or add your work light."
    /// Neutral warm-up line while the first reading settles.
    static let checking = "Checking light…"
    /// Live prompt when the walk hits a dark spot. No spatial description —
    /// this session has no room geometry to name a location with.
    static let lowSpotHit = "Low light here — try adding light in this area."
    /// Summary when the walk's worst reading stayed in the good band.
    static let lightGoodThroughout = "Light looks good throughout."
    static let doneChecking = "Done Checking"
    static let checkAgain = "Check Light Again"
    /// Fail-open report line when the check produced no reading at all.
    static let checkUnavailable = "The light couldn't be checked — you can still start the visit."
    /// Instruction on the dedicated light-check screen.
    static let walkInstruction = "Walk the room slowly with the phone up — the camera reads the light as you go."
}

/// The survey's full lifecycle, as the UI must render it. Every state is
/// visibly distinct from the others — the original sin of v1 was that
/// "never started", "session died", and "light is fine" all rendered as
/// the same silent, tappable screen, which made a field test undiagnosable.
enum GateStatus: Equatable {
    /// Not sampling (before start(), after stop()). Fails open.
    case idle
    /// Sampling has begun but no reading exists yet. Start AND Done are
    /// HELD — nothing has been measured. Bounded by
    /// `warmupTimeoutSeconds`, after which the gate goes .unavailable.
    case checking
    /// The walk is live: samples are flowing, and the band tracks the
    /// WORST reading seen so far — a dark corner sticks even after
    /// walking back into good light. Start stays held until the
    /// estimator taps Done Checking.
    case surveying(worst: LightBand)
    /// Done Checking was tapped: the walk's verdict, from its worst
    /// reading. Dark keeps Start disabled until a re-check clears it.
    case complete(worst: LightBand)
    /// The session failed, timed out, or isn't supported: fail open
    /// (Start enabled), with the reason surfaced in DEBUG builds.
    case unavailable(reason: String)

    var allowsStart: Bool {
        switch self {
        case .idle, .unavailable: return true // fail open — never brick a visit
        case .checking: return false // nothing measured yet
        case .surveying: return false // walk in progress — finish it first
        case .complete(let worst): return worst.allowsStart
        }
    }

    /// Whether "Done Checking" may be tapped: only once at least one
    /// sample has been read.
    var canFinish: Bool {
        if case .surveying = self { return true }
        return false
    }

    /// User-facing line, if any.
    var message: String? {
        switch self {
        case .checking: return LightingGateCopy.checking
        case .surveying(let worst):
            return worst == .dark ? LightingGateCopy.lowSpotHit : nil
        case .complete(let worst):
            return worst == .good ? LightingGateCopy.lightGoodThroughout : worst.message
        case .idle, .unavailable: return nil
        }
    }
}

/// The gate's verdict bands. Pure function of the median — no ARKit here,
/// so threshold behaviour is unit-testable with synthetic values.
enum LightBand: Equatable {
    /// No usable median yet (sampling just started, or the device gave no
    /// light estimate). The gate FAILS OPEN on this: an unavailable reading
    /// must never brick visit capture. Logged so the campaign sees it.
    case unknown
    case good // proceed silently
    case dim // warn, allow proceeding
    case dark // hold: disable Start until the median recovers

    /// Band for any reading — a live sample, a rolling median, or the
    /// walk's worst point. The thresholds don't care which.
    static func forReading(_ lumens: Double?) -> LightBand {
        guard let lumens else { return .unknown }
        if lumens >= LightThresholds.proceedMinLumens { return .good }
        if lumens >= LightThresholds.holdBelowLumens { return .dim }
        return .dark
    }

    /// Whether Start Scan may be tapped in this band.
    var allowsStart: Bool { self != .dark }

    /// The message to show, if any (warn and hold share one line).
    var message: String? {
        switch self {
        case .good, .unknown: return nil
        case .dim, .dark: return LightingGateCopy.moreLightNeeded
        }
    }
}

/// Rolling median over a time window. Pure and deterministic — the
/// ARSession feeds it, tests feed it synthetic values.
struct LightSampleWindow {
    private(set) var samples: [(time: TimeInterval, lumens: Double)] = []
    let windowSeconds: TimeInterval

    init(windowSeconds: TimeInterval = LightThresholds.medianWindowSeconds) {
        self.windowSeconds = windowSeconds
    }

    mutating func append(lumens: Double, at time: TimeInterval) {
        samples.append((time, lumens))
        let cutoff = time - windowSeconds
        samples.removeAll { $0.time < cutoff }
    }

    /// Median of the samples currently in the window; nil when empty.
    var medianLumens: Double? {
        guard !samples.isEmpty else { return nil }
        let sorted = samples.map(\.lumens).sorted()
        let mid = sorted.count / 2
        if sorted.count % 2 == 1 { return sorted[mid] }
        return (sorted[mid - 1] + sorted[mid]) / 2
    }

    var band: LightBand { LightBand.forReading(medianLumens) }
}

/// Owns the sampling ARSession. Lifecycle is bound to the pre-scan screen:
/// `start()` on appear, `stop()` before the RoomPlan capture launches (and
/// on cancel). `stop()` pauses the session and drops the delegate so no AR
/// resources leak into the RoomCaptureSession that starts next.
@MainActor
final class LightingGateController: NSObject, ObservableObject {
    @Published private(set) var status: GateStatus = .idle
    /// The most recent reading — drives the live "Checking light… N lm" line.
    @Published private(set) var currentLumens: Double?
    /// The WORST reading of the walk — drives the gate decision. A dark
    /// corner sticks even after returning to good light.
    @Published private(set) var worstLumens: Double?
    /// Rolling median, kept for the threshold-tuning campaign's logs, not
    /// for the gate decision.
    @Published private(set) var medianLumens: Double?
    /// How many distinct times the walk dropped out of the good band —
    /// "2 low-light spots" reads better on the report than a bare minimum.
    /// A dim→dark slide inside one dark stretch counts once.
    @Published private(set) var lowLightMoments = 0
    private var lastSampleBand: LightBand?

    private var session: ARSession?
    private var window = LightSampleWindow()
    /// Samples actually ingested (post-throttle). Read-only outside; also
    /// the tuning campaign's sample count in the stop() log line.
    private(set) var sampleCount = 0
    private var isSampling = false
    private var warmupTask: Task<Void, Never>?
    // Frame-level diagnostics: split "no frames at all" (camera never
    // started) from "frames without light estimates" — two different
    // failures that both looked like a silent 4s timeout in the field.
    private var framesSeen = 0
    private var framesWithoutEstimate = 0
    private var lastAcceptedSampleAt: TimeInterval = -.infinity
    /// Accept at most ~5 samples/s. ARKit delivers 60 fps; ingesting every
    /// frame flooded the main run loop (a published-var UI invalidation per
    /// frame) until autoreleased ARFrames piled up — ARKit's own field-log
    /// warning: "The delegate of ARSession is retaining 11 ARFrames. The
    /// camera will stop delivering camera images…". 5 Hz is ample for a
    /// walking survey.
    private static let minSampleInterval: TimeInterval = 0.2

    /// ARKit needs a camera; on unsupported hardware the gate reports
    /// .unavailable and fails open (the LiDAR gate in VisitController is
    /// the one that refuses unsupported devices).
    static var isSupported: Bool { ARWorldTrackingConfiguration.isSupported }

    func start() {
        // Every early return is logged and surfaced: v1's silent guard made
        // "start() never ran" indistinguishable from "gate is happy".
        guard !isSampling else {
            visitLog.info("Lighting gate: start() ignored — already sampling")
            return
        }
        guard Self.isSupported else {
            visitLog.error("Lighting gate: start() aborted — ARWorldTracking unsupported (gate fails open)")
            status = .unavailable(reason: "ARKit unsupported on this device")
            return
        }
        activate()

        let configuration = ARWorldTrackingConfiguration()
        configuration.planeDetection = [] // light only — no reconstruction work
        configuration.isLightEstimationEnabled = true
        let session = ARSession()
        session.delegate = self
        session.run(configuration)
        self.session = session
        visitLog.notice("Lighting gate: start() ran — surveying (warm-up timeout \(LightThresholds.warmupTimeoutSeconds)s)")
        armWarmupTimeout()
    }

    /// Bound the warm-up: a session that never produces a sample (camera
    /// denied, resource conflict) must fail open visibly, not hold Start
    /// and Done hostage or die in silence. Re-armed by checkAgain() too.
    private func armWarmupTimeout() {
        warmupTask?.cancel()
        warmupTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(LightThresholds.warmupTimeoutSeconds))
            guard !Task.isCancelled else { return }
            self?.warmupTimedOut()
        }
    }

    /// Tears the sampling session down completely. Safe to call twice.
    /// MUST run before RoomCaptureSession/View starts.
    func stop() {
        guard isSampling else { return }
        isSampling = false
        warmupTask?.cancel()
        warmupTask = nil
        session?.delegate = nil
        session?.pause()
        session = nil
        // The tuning-campaign log line: same channel as the rest of the
        // scan-session metadata (visitLog, Console.app subsystem
        // "com.buildpilot.app").
        let median = medianLumens.map { String(format: "%.0f", $0) } ?? "none"
        let worst = worstLumens.map { String(format: "%.0f", $0) } ?? "none"
        // .notice: this is the tuning campaign's record of the visit's
        // light — it must survive to a later syslog pull (.info does not).
        visitLog.notice("Lighting gate: stopped — worst \(worst) lm, median \(median) lm, status \(String(describing: self.status)), \(self.sampleCount) samples")
        status = .idle
    }

    /// Frame intake: counts every frame (diagnostics), drops estimate-less
    /// frames, and throttles the rest to minSampleInterval before they
    /// reach ingest(). Delegate-only; tests drive ingest() directly.
    func receive(lumens: Double?, at time: TimeInterval) {
        guard isSampling else { return }
        framesSeen += 1
        if framesSeen == 1 {
            visitLog.notice("Lighting gate: first frame (light estimate: \(lumens != nil ? "yes" : "no"))")
        }
        guard let lumens else {
            framesWithoutEstimate += 1
            return
        }
        guard time - lastAcceptedSampleAt >= Self.minSampleInterval else { return }
        lastAcceptedSampleAt = time
        ingest(lumens: lumens, at: time)
    }

    /// Internal (not private) so the teardown/failure paths are unit-testable
    /// without an ARSession — the delegate is the only production caller.
    func ingest(lumens: Double, at time: TimeInterval) {
        // A frame already in flight when stop() ran must not resurrect the
        // gate's state after teardown (or re-disable Start post-handoff).
        guard isSampling else { return }
        // Terminal-until-user-action states ignore frames: a completed
        // summary must not be reopened by a late frame, and a fail-open
        // verdict (session failure / warm-up timeout) must not be undone
        // by a stale in-flight frame — that could re-hold Start on the
        // word of a session already declared dead. Only Check Again or a
        // fresh start() re-enters sampling.
        switch status {
        case .complete, .unavailable: return
        case .idle, .checking, .surveying: break
        }
        if sampleCount == 0 {
            warmupTask?.cancel()
            warmupTask = nil
            // .notice persists to the device log store (unlike .info) — a
            // field session must be reconstructable from a later syslog pull.
            visitLog.notice("Lighting gate: first sample \(Int(lumens)) lumens")
        }
        sampleCount += 1
        currentLumens = lumens
        window.append(lumens: lumens, at: time)
        medianLumens = window.medianLumens
        worstLumens = min(worstLumens ?? lumens, lumens)
        let sampleBand = LightBand.forReading(lumens)
        if sampleBand != .good, lastSampleBand == nil || lastSampleBand == .good {
            lowLightMoments += 1
        }
        lastSampleBand = sampleBand
        let newStatus = GateStatus.surveying(worst: LightBand.forReading(worstLumens))
        if newStatus != status {
            status = newStatus
            visitLog.notice("Lighting gate: status → \(String(describing: newStatus)) (worst \(Int(self.worstLumens ?? -1)) lm, current \(Int(lumens)) lm)")
        }
    }

    /// "Done Checking": the walk's verdict, from its worst reading. The
    /// session stays alive (frames ignored) so Check Again is instant;
    /// stop() still tears everything down before RoomPlan starts.
    func finishSurvey() {
        guard case .surveying(let worst) = status else { return }
        status = .complete(worst: worst)
        let median = medianLumens.map { String(format: "%.0f", $0) } ?? "none"
        visitLog.notice("Lighting gate: survey done — worst \(Int(self.worstLumens ?? -1)) lm (\(String(describing: worst))), median \(median) lm, \(self.sampleCount) samples")
    }

    /// Re-walk after adding light: clears the worst reading and the
    /// summary. Samples resume on the next frame.
    func checkAgain() {
        guard isSampling else { return }
        window = LightSampleWindow()
        sampleCount = 0
        currentLumens = nil
        worstLumens = nil
        medianLumens = nil
        lowLightMoments = 0
        lastSampleBand = nil
        framesSeen = 0
        framesWithoutEstimate = 0
        lastAcceptedSampleAt = -.infinity
        status = .checking
        armWarmupTimeout() // a re-check must not hang forever either
        visitLog.notice("Lighting gate: re-checking after summary")
    }
}

extension LightingGateController: ARSessionDelegate {
    nonisolated func session(_ session: ARSession, didUpdate frame: ARFrame) {
        // Scalars only — the ARFrame must not outlive this callback.
        // Processing is synchronous on the main actor (ARSession calls its
        // delegate on the main queue when delegateQueue is unset — we never
        // set it), so no frame is ever queued behind a Task hop. The
        // previous per-frame Task enqueue backed up the run loop until
        // ARKit warned it was stopping camera delivery over retained frames.
        let lumens = frame.lightEstimate.map { Double($0.ambientIntensity) }
        let time = frame.timestamp
        MainActor.assumeIsolated {
            self.receive(lumens: lumens, at: time)
        }
    }

    nonisolated func session(_ session: ARSession, didFailWithError error: Error) {
        visitLog.error("Lighting gate: AR session failed (gate fails open): \(error.localizedDescription)")
        Task { @MainActor in
            self.handleSessionFailure(reason: error.localizedDescription)
        }
    }
}

extension LightingGateController {
    /// Resets state and opens the gate for samples. Split from start() so
    /// the ingest/teardown/failure logic is unit-testable off-device, where
    /// ARWorldTrackingConfiguration.isSupported is false.
    func activate() {
        isSampling = true
        window = LightSampleWindow()
        sampleCount = 0
        status = .checking
        currentLumens = nil
        worstLumens = nil
        medianLumens = nil
        lowLightMoments = 0
        lastSampleBand = nil
        framesSeen = 0
        framesWithoutEstimate = 0
        lastAcceptedSampleAt = -.infinity
    }

    /// Fail open: with the session dead there will be no further samples, so
    /// a lingering .dark verdict would disable Start forever — and a silent
    /// .checking would hold it hostage. Unavailable allows Start and, in
    /// DEBUG builds, says why.
    func handleSessionFailure(reason: String) {
        guard isSampling else { return }
        window = LightSampleWindow()
        currentLumens = nil
        worstLumens = nil
        medianLumens = nil
        lowLightMoments = 0
        lastSampleBand = nil
        status = .unavailable(reason: reason)
    }

    /// No sample arrived within the warm-up bound. Same fail-open shape as
    /// a session failure — the distinction lives in the logged reason,
    /// which now says whether the camera delivered ANY frames: "camera
    /// never started" and "frames without light estimates" are different
    /// bugs that both used to look like this same silent timeout.
    func warmupTimedOut() {
        guard isSampling, status == .checking else { return }
        let detail = framesSeen == 0
            ? "no camera frames at all"
            : "\(framesSeen) frames, \(framesWithoutEstimate) without a light estimate"
        visitLog.error("Lighting gate: no samples within \(LightThresholds.warmupTimeoutSeconds)s (\(detail)) — unavailable, failing open")
        status = .unavailable(reason: "no light samples within \(Int(LightThresholds.warmupTimeoutSeconds))s (\(detail))")
    }

    /// The live user-facing meter for the walk: "Checking light… 340 lm".
    /// No longer a developer diagnostic — the survey is a real client-facing
    /// moment and doubles as the live meter for the threshold campaign.
    var liveReadout: String? {
        guard case .surveying = status, let current = currentLumens else { return nil }
        return "\(LightingGateCopy.checking) \(Int(current)) lm"
    }

    /// One-line readout for the DEBUG status footnote: makes "working and
    /// happy", "still warming up", and "dead" visibly different on a test
    /// build, including states the release UI deliberately keeps silent.
    var debugReadout: String {
        switch status {
        case .idle: return "light check idle"
        case .checking: return "light check warming up…"
        case .surveying(let worst):
            let current = currentLumens.map { String(Int($0)) } ?? "—"
            let low = worstLumens.map { String(Int($0)) } ?? "—"
            return "light now \(current) lm · worst \(low) lm · \(String(describing: worst))"
        case .complete(let worst):
            let low = worstLumens.map { String(Int($0)) } ?? "—"
            return "survey done · worst \(low) lm · \(String(describing: worst))"
        case .unavailable(let reason): return "light check unavailable — \(reason)"
        }
    }
}
