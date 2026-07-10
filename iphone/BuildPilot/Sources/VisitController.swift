import Foundation
import SwiftUI

/// The visit state machine: idle → scanning → processing → estimate/failed.
@MainActor
final class VisitController: ObservableObject {
    enum Phase: Equatable {
        case idle
        case scanning
        case processing(String) // progress label
        case done(SessionResponse)
        case failed(String)

        static func == (lhs: Phase, rhs: Phase) -> Bool {
            switch (lhs, rhs) {
            case (.idle, .idle), (.scanning, .scanning),
                 (.processing, .processing), (.done, .done), (.failed, .failed):
                return true
            default:
                return false
            }
        }
    }

    @Published var phase: Phase = .idle
    @AppStorage("backendURL") var backendURLString = "http://192.168.1.100:8787"

    let roomCapture = RoomCaptureController()
    private let audioRecorder = AudioRecorder()

    var deviceSupported: Bool { RoomCaptureController.isSupported }

    func startVisit() async {
        guard deviceSupported else {
            phase = .failed("This device does not support RoomPlan (LiDAR required).")
            return
        }
        guard URL(string: backendURLString) != nil else {
            phase = .failed("Backend URL is not valid.")
            return
        }
        guard await audioRecorder.requestPermission() else {
            phase = .failed("Microphone permission is required to record the visit.")
            return
        }
        do {
            try audioRecorder.start()
        } catch {
            phase = .failed("Could not start audio recording: \(error.localizedDescription)")
            return
        }
        roomCapture.start()
        phase = .scanning
    }

    func finishVisit() {
        guard phase == .scanning else { return }
        phase = .processing("Finalizing room scan…")
        let audioFile = audioRecorder.stop()

        roomCapture.onFinalResult = { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                switch result {
                case .success(let roomJSON):
                    await self.uploadBundle(roomJSON: roomJSON, audioFile: audioFile)
                case .failure(let error):
                    self.phase = .failed("Room scan failed: \(error.localizedDescription)")
                }
            }
        }
        roomCapture.stop()
    }

    func reset() {
        phase = .idle
    }

    private func uploadBundle(roomJSON: Data, audioFile: URL?) async {
        guard let url = URL(string: backendURLString) else {
            phase = .failed("Backend URL is not valid.")
            return
        }
        phase = .processing("Sending to Mac and drafting estimate…")
        do {
            let session = try await SessionUploader(backendURL: url)
                .upload(roomScan: roomJSON, audioFile: audioFile)
            if session.status == "completed" {
                phase = .done(session)
            } else {
                let detail = session.rawMetadata?["error"] ?? "processing failed"
                phase = .failed("Backend could not process the visit: \(detail)")
            }
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }
}
