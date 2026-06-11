import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menubar-only: no Dock icon, no app switcher entry. Windows we open
        // ourselves (e.g. the New Worktree panel) still work.
        NSApp.setActivationPolicy(.accessory)
    }
}

@main
struct SparkPlugApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            ContentView()
                .frame(width: 640, height: 540)
        } label: {
            Image(systemName: "bolt.fill")
        }
        .menuBarExtraStyle(.window)
    }
}
