import SwiftUI

@main
struct BuildPilotApp: App {
    init() {
        visitLog.info("App init — process started")
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .onAppear { visitLog.info("ContentView appeared — first frame rendered") }
        }
    }
}
