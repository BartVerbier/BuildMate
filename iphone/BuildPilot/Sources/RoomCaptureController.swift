import ARKit
import CoreImage
import Foundation
import RoomPlan
import UIKit

/// Owns the RoomCaptureView and its session; publishes the encoded
/// CapturedRoom JSON when scanning finishes.
///
/// Design rule (docs/DECISIONS.md, Decision 10): the phone sends Apple's
/// CapturedRoom JSON verbatim — no transformation, no unit conversion.
final class RoomCaptureController: NSObject, ObservableObject {
    static var isSupported: Bool { RoomCaptureSession.isSupported }

    let captureView: RoomCaptureView
    @Published private(set) var isScanning = false

    /// Called exactly once per scan with the encoded CapturedRoom JSON,
    /// or an error if processing failed.
    var onFinalResult: ((Result<Data, Error>) -> Void)?

    // MARK: automatic Before photos
    //
    // RoomPlan owns the camera, but its ARSession exposes live frames.
    // We *poll* currentFrame on a timer (never touching RoomPlan's session
    // delegate), JPEG-encode a sample every few seconds, and keep the
    // sharpest few — JPEG size at fixed quality is a cheap, reliable proxy
    // for image detail/sharpness.
    private static let frameSampleInterval: TimeInterval = 2.5
    private static let maxKeptFrames = 3
    private static let ciContext = CIContext()

    /// A sampled frame with its quality score. Scoring criteria:
    /// - sharpness: variance of the Laplacian on a 64x64 grayscale thumb
    /// - levelness: camera pitch from ARKit — a level camera faces walls
    ///   (the best proxy for "largest visible wall" without semantic vision)
    /// - exposure: luma mean distance from ideal — penalizes dark/blown frames
    struct FrameCandidate {
        let jpeg: Data
        let score: Double
        let t: Double // seconds on the visit clock (audio start = 0)
        let detail: String // for diagnostics: "sharp 0.71 level 0.94 expo 0.88"
    }

    /// One camera pose on the visit clock. ARKit and RoomPlan share a world
    /// frame, so these poses let the backend resolve which wall the camera
    /// (and the conversation) was pointing at, and how completely a wall
    /// fits in a frame. Column-major 4x4 transform; sensor-space intrinsics.
    struct PoseSample: Codable {
        let t: Double
        let transform: [Double] // 16 values, column-major
        let fx, fy, cx, cy: Double
        let w, h: Int
    }

    private var frameTimer: Timer?
    private var frameCandidates: [FrameCandidate] = []
    private var poseSamples: [PoseSample] = []
    /// The visit clock's zero point — the moment audio recording started.
    private var clockReference = Date()

    override init() {
        captureView = RoomCaptureView(frame: .zero)
        super.init()
        captureView.delegate = self
    }

    func start(clockReference: Date = Date()) {
        guard !isScanning else { return }
        isScanning = true
        frameCandidates = []
        poseSamples = []
        self.clockReference = clockReference
        captureView.captureSession.run(configuration: RoomCaptureSession.Configuration())
        frameTimer = Timer.scheduledTimer(
            withTimeInterval: Self.frameSampleInterval, repeats: true
        ) { [weak self] _ in
            self?.sampleFrame()
        }
    }

    func stop() {
        guard isScanning else { return }
        isScanning = false
        frameTimer?.invalidate()
        frameTimer = nil
        // Stopping triggers RoomPlan's final processing pass; the result
        // arrives via captureView(didPresent:error:).
        captureView.captureSession.stop()
    }

    /// The best-scoring frames from the scan, ordered best-first, each with
    /// its capture time on the visit clock. Call after stop().
    func bestBeforePhotos() -> [(image: UIImage, t: Double)] {
        let selected = frameCandidates
            .sorted { $0.score > $1.score }
            .prefix(Self.maxKeptFrames)
        visitLog.info("Before-photo selection: \(self.frameCandidates.count) candidates → kept \(selected.count): \(selected.map(\.detail).joined(separator: " | "))")
        return selected.compactMap { candidate in
            UIImage(data: candidate.jpeg).map { ($0, candidate.t) }
        }
    }

    /// The scan's camera pose log, JSON-encoded for upload. Call after stop().
    func posesJSON() -> Data? {
        guard !poseSamples.isEmpty else { return nil }
        return try? JSONEncoder().encode(poseSamples)
    }

    private func sampleFrame() {
        guard isScanning,
              let frame = captureView.captureSession.arSession.currentFrame
        else { return }

        // Pose first — logged for every tick, even when the photo is skipped.
        let t = Date().timeIntervalSince(clockReference)
        let m = frame.camera.transform
        let k = frame.camera.intrinsics
        let resolution = frame.camera.imageResolution
        poseSamples.append(PoseSample(
            t: t,
            transform: [m.columns.0, m.columns.1, m.columns.2, m.columns.3]
                .flatMap { [Double($0.x), Double($0.y), Double($0.z), Double($0.w)] },
            fx: Double(k.columns.0.x), fy: Double(k.columns.1.y),
            cx: Double(k.columns.2.x), cy: Double(k.columns.2.y),
            w: Int(resolution.width), h: Int(resolution.height)
        ))

        // Angle first (the customer-presentation priority): pitch 0 = camera
        // level and wall-facing — the best proxy for "largest visible wall,
        // straight on". Roll penalizes crooked horizons that make renders
        // look amateur.
        let pitch = Double(frame.camera.eulerAngles.x)
        let roll = Double(frame.camera.eulerAngles.z)
        let pitchScore = max(0, 1 - abs(pitch) / (.pi / 4))
        let rollScore = max(0, 1 - abs(roll) / (.pi / 8))
        let levelness = pitchScore * rollScore

        let ciImage = CIImage(cvPixelBuffer: frame.capturedImage)
        guard let cgImage = Self.ciContext.createCGImage(ciImage, from: ciImage.extent) else { return }
        let (sharpness, exposure) = Self.imageQuality(cgImage)

        let score = 0.45 * levelness + 0.35 * sharpness + 0.20 * exposure
        // Sensor frames are landscape; rotate to the portrait the painter saw.
        let image = UIImage(cgImage: cgImage, scale: 1, orientation: .right)
        guard let jpeg = image.jpegData(compressionQuality: 0.8) else { return }

        let detail = String(format: "sharp %.2f level %.2f expo %.2f → %.2f", sharpness, levelness, exposure, score)
        frameCandidates.append(FrameCandidate(jpeg: jpeg, score: score, t: t, detail: detail))
        // Bound memory: keep only the best dozen candidates while scanning.
        if frameCandidates.count > 12 {
            frameCandidates.sort { $0.score > $1.score }
            frameCandidates.removeLast(frameCandidates.count - 12)
        }
        visitLog.debug("Sampled frame: \(detail)")
    }

    /// Sharpness (Laplacian variance) and exposure quality from a 64x64
    /// grayscale thumbnail. Deterministic, ~instant.
    private static func imageQuality(_ cgImage: CGImage) -> (sharpness: Double, exposure: Double) {
        let side = 64
        var pixels = [UInt8](repeating: 0, count: side * side)
        guard let context = CGContext(
            data: &pixels, width: side, height: side, bitsPerComponent: 8,
            bytesPerRow: side, space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return (0.5, 0.5) }
        context.interpolationQuality = .medium
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: side, height: side))

        // Laplacian variance
        var laplacians: [Double] = []
        laplacians.reserveCapacity((side - 2) * (side - 2))
        var lumaSum = 0.0
        for y in 1 ..< side - 1 {
            for x in 1 ..< side - 1 {
                let i = y * side + x
                let center = Double(pixels[i])
                let lap = 4 * center
                    - Double(pixels[i - 1]) - Double(pixels[i + 1])
                    - Double(pixels[i - side]) - Double(pixels[i + side])
                laplacians.append(lap)
                lumaSum += center
            }
        }
        let mean = laplacians.reduce(0, +) / Double(laplacians.count)
        let variance = laplacians.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(laplacians.count)
        let sharpness = min(variance / 400.0, 1.0)

        // Exposure: ideal mean luma ~128; linear falloff to 0 at the extremes.
        let luma = lumaSum / Double(laplacians.count)
        let exposure = max(0, 1 - abs(luma - 128) / 128)
        return (sharpness, exposure)
    }
}

// RoomCaptureViewDelegate requires NSCoding; the conformance below is
// deliberately inert — this object is never actually archived.
extension RoomCaptureController: RoomCaptureViewDelegate {
    func captureView(shouldPresent roomDataForProcessing: CapturedRoomData, error: Error?) -> Bool {
        true // always run RoomPlan's final processing pass
    }

    func captureView(didPresent processedResult: CapturedRoom, error: Error?) {
        if let error {
            onFinalResult?(.failure(error))
            return
        }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(processedResult)
            onFinalResult?(.success(data))
        } catch {
            onFinalResult?(.failure(error))
        }
    }

    func encode(with coder: NSCoder) {}

    convenience init?(coder: NSCoder) {
        self.init()
    }
}
