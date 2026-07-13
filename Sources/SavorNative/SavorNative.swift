import AppKit
import Combine
import SwiftUI

@main
struct SavorNativeApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .onReceive(
                    NotificationCenter.default.publisher(
                        for: NSApplication.willTerminateNotification
                    )
                ) { _ in
                    model.cancelCurrentCapture()
                }
        }
        .defaultSize(width: 1_080, height: 720)
        .windowStyle(.hiddenTitleBar)
    }
}
