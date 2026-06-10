import SwiftUI
import AppKit

/// Hosts the New Worktree form in its own small floating window. The menubar
/// popover can't contain this flow — it auto-closes the moment an NSOpenPanel
/// becomes key — so the form lives in a real window the popover hands off to.
@MainActor
final class NewWorktreePanel {
    static let shared = NewWorktreePanel()
    private var window: NSWindow?

    func show() {
        // Always start fresh: a previously closed window keeps stale form state.
        if let existing = window, existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let form = NewWorktreeForm(store: .shared) { [weak self] in
            self?.dismiss()
        }
        let hosting = NSHostingController(rootView: form)
        let w = NSWindow(contentViewController: hosting)
        w.title = "New Worktree"
        w.styleMask = [.titled, .closable]
        w.isReleasedWhenClosed = false
        w.level = .floating
        w.center()
        window = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func dismiss() {
        window?.close()
        window = nil
    }
}
