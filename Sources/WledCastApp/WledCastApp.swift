import SwiftUI

@main
struct WledCastApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup("WledCast", id: "main") {
            SettingsView()
                .environmentObject(model)
                .frame(width: 360, height: 520)
        }
        MenuBarExtra("WledCast", systemImage: model.isStreaming ? "dot.radiowaves.left.and.right" : "square.dashed") {
            MenuBarContent()
                .environmentObject(model)
                .frame(width: 320)
        }
    }
}
