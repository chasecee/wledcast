import SwiftUI

@main
struct WledCastApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra("WledCast", systemImage: model.isStreaming ? "dot.radiowaves.left.and.right" : "square.dashed") {
            MenuBarContent()
                .environmentObject(model)
                .frame(width: 320)
        }
    }
}
