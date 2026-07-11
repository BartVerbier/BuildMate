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
        let detail: String // for diagnostics: "sharp 0.71 level 0.94 expo 0.88"
    }

    private var frameTimer: Timer?
    private var frameCandidates: [FrameCandidate] = []

    override init() {
        captureView = RoomCaptureView(frame: .zero)
        super.init()
        captureView.delegate = self
    }

    func start() {
        guard !isScanning else { return }
        isScanning = true
        frameCandidates = []
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

    /// The best-scoring frames from the scan, ordered best-first, ready to
    /// be saved as the visit's Before photos. Call after stop().
    func bestBeforePhotos() -> [UIImage] {
        let selected = frameCandidates
            .sorted { $0.score > $1.score }
            .prefix(Self.maxKeptFrames)
        visitLog.info("Before-photo selection: \(self.frameCandidates.count) candidates → kept \(selected.count): \(selected.map(\.detail).joined(separator: " | "))")
        return selected.compactMap { UIImage(data: $0.jpeg) }
    }

    private func sampleFrame() {
        guard isScanning,
              let frame = captureView.captureSession.arSession.currentFrame
        else { return }

        // Levelness: pitch 0 = camera level (facing walls). Frames aimed at
        // floor/ceiling score toward 0. Ties naturally prefer the frame with
        // the most wall in view.
        let pitch = Double(frame.camera.eulerAngles.x)
        let levelness = max(0, 1 - abs(pitch) / (.pi / 4))

        let ciImage = CIImage(cvPixelBuffer: frame.capturedImage)
        guard let cgImage = Self.ciContext.createCGImage(ciImage, from: ciImage.extent) else { return }
        let (sharpness, exposure) = Self.imageQuality(cgImage)

        let score = 0.45 * sharpness + 0.35 * levelness + 0.20 * exposure
        // Sensor frames are landscape; rotate to the portrait the painter saw.
        let image = UIImage(cgImage: cgImage, scale: 1, orientation: .right)
        guard let jpeg = image.jpegData(compressionQuality: 0.8) else { return }

        let detail = String(format: "sharp %.2f level %.2f expo %.2f → %.2f", sharpness, levelness, exposure, score)
        frameCandidates.append(FrameCandidate(jpeg: jpeg, score: score, detail: detail))
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
