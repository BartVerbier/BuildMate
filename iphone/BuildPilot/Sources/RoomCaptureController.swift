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

    override init() {
        captureView = RoomCaptureView(frame: .zero)
        super.init()
        captureView.delegate = self
    }

    func start() {
        guard !isScanning else { return }
        isScanning = true
        captureView.captureSession.run(configuration: RoomCaptureSession.Configuration())
    }

    func stop() {
        guard isScanning else { return }
        isScanning = false
        // Stopping triggers RoomPlan's final processing pass; the result
        // arrives via captureView(didPresent:error:).
        captureView.captureSession.stop()
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
