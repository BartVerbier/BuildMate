import RoomPlan
import SwiftUI

/// SwiftUI wrapper around the RoomCaptureView owned by RoomCaptureController.
struct RoomCaptureViewRepresentable: UIViewRepresentable {
    let controller: RoomCaptureController

    func makeUIView(context: Context) -> RoomCaptureView {
        controller.captureView
    }

    func updateUIView(_ uiView: RoomCaptureView, context: Context) {}
}
