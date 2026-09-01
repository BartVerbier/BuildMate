#if DEBUG
import ARKit
import RoomPlan
import SwiftUI

/// AR-continuity spike (internal, DEBUG-only). Proves that after RoomPlan
/// finishes, the app can keep using live camera poses in the SAME world frame
/// as the captured wall transforms — the make-or-break assumption for the
/// guided per-wall capture (Stage 0.5).
///
/// It is fully self-contained: its own RoomCaptureView and ARSession, no visit,
/// no upload, no estimator, no /visualize. Nothing here runs in Release.
///
/// Continuity technique: after the geometry is finalized we resume the SAME
/// ARSession with `run(config, options: [])` — NO `.resetTracking` /
/// `.removeExistingAnchors` — so the scan's world origin is preserved. We never
/// start a second world origin (per the spike constraint). If tracking is lost
/// or relocalizing we REPORT it and stop updating rather than draw stale walls.
final class ARContinuitySpikeController: NSObject, ObservableObject {
    enum Phase: Equatable {
        case scanning
        case continuity
        case failed(String)
    }

    struct Diagnostics {
        var wallCount = 0
        var targetWallId = "—"
        var facingWallId = "—"
        var facesTarget = false
        var distanceM: Float = 0
        var angleDeg: Float = 0
        var cornersInFrame = 0
        var trackingState = "—"
        var poseUpdating = false
        var frameAgeMs = 0
    }

    @Published private(set) var phase: Phase = .scanning
    @Published private(set) var diag = Diagnostics()

    let captureView = RoomCaptureView(frame: .zero)
    private var walls: [WallQuad] = []
    private var target: WallQuad?
    private var timer: Timer?
    private var lastTimestamp: TimeInterval = 0

    override init() {
        super.init()
        captureView.delegate = self
    }

    func startScan() {
        phase = .scanning
        walls = []
        target = nil
        captureView.captureSession.run(configuration: RoomCaptureSession.Configuration())
    }

    /// Finish the geometry pass — triggers `captureView(didPresent:)`.
    func finishScan() {
        captureView.captureSession.stop()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        captureView.captureSession.stop()
        captureView.captureSession.arSession.pause()
    }

    // MARK: - continuity

    private func beginContinuity(_ room: CapturedRoom) {
        // Substantial walls only (skip small fragments), positional ids "w1"…
        walls = WallGeometry.quads(from: room.walls).filter { $0.areaM2 >= 1.0 }
        target = walls.max { $0.areaM2 < $1.areaM2 }
        diag.wallCount = walls.count
        diag.targetWallId = target?.id ?? "—"
        guard target != nil else {
            phase = .failed("No substantial wall was reconstructed.")
            return
        }

        // Resume the SAME session in place — empty options keep the world origin.
        let session = captureView.captureSession.arSession
        session.delegate = self
        session.run(ARWorldTrackingConfiguration(), options: [])
        phase = .continuity

        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.sample()
        }
    }

    private func sample() {
        guard let frame = captureView.captureSession.arSession.currentFrame,
              let target else { return }

        // Report tracking state honestly; never use stale geometry silently.
        switch frame.camera.trackingState {
        case .normal: diag.trackingState = "normal"
        case .notAvailable: diag.trackingState = "notAvailable"
        case let .limited(reason): diag.trackingState = "limited(\(reason))"
        }
        diag.poseUpdating = frame.timestamp != lastTimestamp
        diag.frameAgeMs = Int((frame.timestamp - lastTimestamp) * 1000)
        lastTimestamp = frame.timestamp

        // Only compute wall metrics when tracking is solid.
        guard case .normal = frame.camera.trackingState else { return }

        let t = frame.camera.transform
        let k = frame.camera.intrinsics
        let sensor = frame.camera.imageResolution
        diag.facingWallId = WallGeometry.facingWall(cameraTransform: t, walls: walls) ?? "—"
        diag.facesTarget = diag.facingWallId == target.id
        diag.distanceM = WallGeometry.distanceM(cameraTransform: t, wall: target)
        diag.angleDeg = WallGeometry.viewAngleDegrees(cameraTransform: t, wall: target)
        diag.cornersInFrame = WallGeometry.cornersInFrame(
            target, cameraTransform: t, intrinsics: k, sensor: sensor
        )
    }

    /// Target-wall outline in view space, using ARKit's orientation-aware
    /// projection (correct on-screen rendering). nil while tracking isn't normal
    /// so the overlay disappears instead of sticking to a stale pose.
    func targetOutline(viewportSize: CGSize, orientation: UIInterfaceOrientation) -> [CGPoint]? {
        guard let frame = captureView.captureSession.arSession.currentFrame, let target else { return nil }
        guard case .normal = frame.camera.trackingState else { return nil }
        return target.cornerLoop.map {
            frame.camera.projectPoint($0, orientation: orientation, viewportSize: viewportSize)
        }
    }
}

extension ARContinuitySpikeController: RoomCaptureViewDelegate {
    func captureView(shouldPresent data: CapturedRoomData, error: Error?) -> Bool { true }

    func captureView(didPresent room: CapturedRoom, error: Error?) {
        if let error {
            phase = .failed(error.localizedDescription)
            return
        }
        beginContinuity(room)
    }

    func encode(with coder: NSCoder) {}
    convenience init?(coder: NSCoder) { self.init() }
}

extension ARContinuitySpikeController: ARSessionDelegate {}

/// Minimal SwiftUI wrapper around a bare RoomCaptureView (the production
/// representable is bound to the production controller).
private struct SpikeCaptureView: UIViewRepresentable {
    let view: RoomCaptureView
    func makeUIView(context: Context) -> RoomCaptureView { view }
    func updateUIView(_ uiView: RoomCaptureView, context: Context) {}
}

struct ARContinuitySpikeView: View {
    @StateObject private var controller = ARContinuitySpikeController()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            SpikeCaptureView(view: controller.captureView).ignoresSafeArea()

            // Projected target-wall outline — the thing to watch: does it stay
            // stuck to the real wall as the phone moves?
            GeometryReader { geo in
                if controller.phase == .continuity,
                   let outline = controller.targetOutline(viewportSize: geo.size, orientation: .portrait),
                   outline.count > 1 {
                    Path { p in
                        p.move(to: outline[0])
                        outline.dropFirst().forEach { p.addLine(to: $0) }
                        p.closeSubpath()
                    }
                    .stroke(controller.diag.facesTarget ? Color.green : Color.orange, lineWidth: 4)
                }
            }
            .allowsHitTesting(false)

            VStack {
                banner
                Spacer()
                if controller.phase == .continuity { diagnosticPanel }
                controls
            }
            .padding()
        }
        .onAppear { controller.startScan() }
        .onDisappear { controller.stop() }
        .navigationTitle("AR Continuity Spike")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var banner: some View {
        Group {
            switch controller.phase {
            case .scanning:
                label("Scan the room, then tap Finish Scan", .yellow)
            case .continuity:
                label("Move the phone — the outline should stay on the wall", .green)
            case let .failed(message):
                label("Failed: \(message)", .red)
            }
        }
    }

    private func label(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(.footnote.weight(.semibold))
            .padding(8)
            .background(color.opacity(0.85), in: Capsule())
            .foregroundStyle(.black)
    }

    private var diagnosticPanel: some View {
        let d = controller.diag
        return VStack(alignment: .leading, spacing: 3) {
            row("walls", "\(d.wallCount)")
            row("target", d.targetWallId)
            row("facing", "\(d.facingWallId)\(d.facesTarget ? " ✓" : "")")
            row("distance", String(format: "%.2f m", d.distanceM))
            row("view angle", String(format: "%.1f°", d.angleDeg))
            row("corners in frame", "\(d.cornersInFrame)/4")
            row("tracking", d.trackingState)
            row("pose updating", d.poseUpdating ? "yes (Δ\(d.frameAgeMs)ms)" : "NO — frozen")
        }
        .font(.system(.caption, design: .monospaced))
        .foregroundStyle(.white)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
    }

    private func row(_ k: String, _ v: String) -> some View {
        HStack { Text(k); Spacer(); Text(v).bold() }
    }

    private var controls: some View {
        HStack(spacing: 12) {
            if controller.phase == .scanning {
                Button("Finish Scan") { controller.finishScan() }
                    .buttonStyle(.borderedProminent).tint(.yellow).foregroundStyle(.black)
            }
            Button("Done") { dismiss() }
                .buttonStyle(.bordered).tint(.white)
        }
        .padding(.top, 8)
    }
}
#endif
