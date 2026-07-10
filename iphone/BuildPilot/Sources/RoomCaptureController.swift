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

    private var frameTimer: Timer?
    private var frameCandidates: [(score: Int, jpeg: Data)] = []

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

    /// The sharpest frames captured during the scan, ready to be saved as
    /// the visit's Before photos. Call after stop().
    func bestBeforePhotos() -> [UIImage] {
        let selected = frameCandidates
            .sorted { $0.score > $1.score }
            .prefix(Self.maxKeptFrames)
        let allScores = frameCandidates.map { $0.score / 1024 }.sorted(by: >)
        visitLog.info("Before-photo selection: \(self.frameCandidates.count) candidates, scores(kB)=\(allScores), selected top \(selected.count)")
        return selected.compactMap { UIImage(data: $0.jpeg) }
    }

    private func sampleFrame() {
        guard isScanning,
              let frame = captureView.captureSession.arSession.currentFrame
        else { return }
        let ciImage = CIImage(cvPixelBuffer: frame.capturedImage)
        guard let cgImage = Self.ciContext.createCGImage(ciImage, from: ciImage.extent) else { return }
        // Sensor frames are landscape; rotate to the portrait the painter saw.
        let image = UIImage(cgImage: cgImage, scale: 1, orientation: .right)
        guard let jpeg = image.jpegData(compressionQuality: 0.8) else { return }

        frameCandidates.append((score: jpeg.count, jpeg: jpeg))
        // Bound memory: keep only the best dozen candidates while scanning.
        if frameCandidates.count > 12 {
            frameCandidates.sort { $0.score > $1.score }
            frameCandidates.removeLast(frameCandidates.count - 12)
        }
        visitLog.debug("Sampled scan frame (\(jpeg.count / 1024) kB), candidates: \(self.frameCandidates.count)")
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
