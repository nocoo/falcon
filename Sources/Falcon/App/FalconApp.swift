import SwiftUI
import FalconCore

@main
struct FalconApp: App {
    var body: some Scene {
        Window("Falcon", id: "main") {
            ContentUnavailableView("Falcon", systemImage: "bird", description: Text("A window into every decision."))
                .frame(minWidth: 1120, minHeight: 720)
        }
        .defaultSize(width: 1600, height: 1000)
    }
}
