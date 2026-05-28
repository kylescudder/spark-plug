import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first?.makeKeyAndOrderFront(nil)
    }
}

@main
struct SparkPlugApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Window("Spark Plug", id: "main") {
            ContentView()
                .frame(minWidth: 560, minHeight: 480)
        }
        .windowResizability(.contentMinSize)

        MenuBarExtra {
            ContentView()
                .frame(width: 640, height: 540)
        } label: {
            Image(systemName: "bolt.fill")
        }
        .menuBarExtraStyle(.window)
    }
}
