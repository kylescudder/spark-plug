import SwiftUI
import AppKit

@main
struct SparkPlugApp: App {
    var body: some Scene {
        Window("Spark Plug", id: "main") {
            ContentView()
                .frame(minWidth: 560, minHeight: 480)
        }
        .windowResizability(.contentMinSize)

        MenuBarExtra {
            ContentView()
                .frame(width: 560, height: 520)
        } label: {
            Image(systemName: "bolt.fill")
        }
        .menuBarExtraStyle(.window)
    }
}
