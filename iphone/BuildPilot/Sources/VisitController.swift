import Foundation
import SwiftUI

/// The visit state machine: idle → scanning → processing → estimate/failed.
@MainActor
final class VisitController: ObservableObject {
    enum ProcessingStage: Int, Comparable {
        case finalizingScan
        case drafting // upload + Mac pipeline (one synchronous call)

        static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    enum Phase {
        case idle
        case scanning
        case processing(ProcessingStage)
        case done(SessionResponse)
        case failed(String)

        var isActiveVisit: Bool {
            if case .idle = self { return false }
            return true
        }
    }

    @Published var phase: Phase = .idle
    @AppStorage("backendURL") var backendURLString = "http://192.168.1.100:8787"

    let roomCapture = RoomCaptureController()
    let history = VisitHistoryStore()
    private let audioRecorder = AudioRecorder()

    private(set) var visitName = ""
    private(set) var scanStartedAt: Date?

    var deviceSupported: Bool { RoomCaptureController.isSupported }

    func startVisit() async {
        guard deviceSupported else {
            phase = .failed("This device does not support RoomPlan — a LiDAR-equipped iPhone is required.")
            return
        }
        guard URL(string: backendURLString) != nil else {
            phase = .failed("The Mac address in Settings is not a valid URL.")
            return
        }
        guard await audioRecorder.requestPermission() else {
            phase = .failed("Build Pilot needs the microphone to record the visit conversation. Enable it in Settings → Privacy.")
            return
        }
        do {
            try audioRecorder.start()
        } catch {
            phase = .failed("Could not start audio recording: \(error.localizedDescription)")
            return
        }
        visitName = Self.defaultVisitName()
        scanStartedAt = Date()
        roomCapture.start()
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
                    await self.uploadBundle(roomJSON: roomJSON, audioFile: audioFile)
                case .failure(let error):
                    self.phase = .failed("Room scan failed: \(error.localizedDescription)")
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

    func reset() {
        scanStartedAt = nil
        phase = .idle
    }

    private func uploadBundle(roomJSON: Data, audioFile: URL?) async {
        guard let url = URL(string: backendURLString) else {
            phase = .failed("The Mac address in Settings is not a valid URL.")
            return
        }
        phase = .processing(.drafting)
        do {
            let session = try await SessionUploader(backendURL: url)
                .upload(roomScan: roomJSON, audioFile: audioFile)
            if session.status == "completed" {
                history.add(name: visitName, session: session)
                phase = .done(session)
            } else {
                let detail = session.rawMetadata?["error"] ?? "processing failed"
                phase = .failed("Your Mac could not process the visit: \(detail)")
            }
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    private static func defaultVisitName() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "d MMM, HH:mm"
        return "Visit — \(formatter.string(from: Date()))"
    }
}
