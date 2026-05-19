import SwiftUI

@main
struct WledCastApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup("WledCast", id: "main") {
            SettingsView()
                .environmentObject(model)
        }
        .defaultSize(width: 360, height: 560)
        .windowResizability(.contentSize)
        MenuBarExtra("WledCast", systemImage: model.isStreaming ? "dot.radiowaves.left.and.right" : "square.dashed") {
            MenuBarContent()
                .environmentObject(model)
                .frame(width: 320)
        }
    }
}
