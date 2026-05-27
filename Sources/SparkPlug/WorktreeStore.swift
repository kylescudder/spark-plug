import SwiftUI
import AppKit

struct Worktree: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let url: URL
    let isGitRepo: Bool
    let sessionCount: Int
    let lastSessionAt: Date?

    var hasClaudeSession: Bool { sessionCount > 0 }
}

@MainActor
final class WorktreeStore: ObservableObject {
    private static let rootKey = "SparkPlug.rootPath"

    @Published var rootPath: String {
        didSet {
            UserDefaults.standard.set(rootPath, forKey: Self.rootKey)
            scan()
        }
    }
    @Published private(set) var worktrees: [Worktree] = []
    @Published var errorMessage: String?

    init() {
        let defaultPath = ("~/worktrees" as NSString).expandingTildeInPath
        self.rootPath = UserDefaults.standard.string(forKey: Self.rootKey) ?? defaultPath
        scan()
    }

    func scan() {
        let fm = FileManager.default
        let expanded = (rootPath as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded)
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
            worktrees = []
            errorMessage = "Folder not found: \(url.path)"
            return
        }
        do {
            let contents = try fm.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
            worktrees = contents
                .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false }
                .map { dir in
                    let gitPath = dir.appendingPathComponent(".git").path
                    let (count, last) = Self.claudeSessionInfo(for: dir)
                    return Worktree(
                        name: dir.lastPathComponent,
                        url: dir,
                        isGitRepo: fm.fileExists(atPath: gitPath),
                        sessionCount: count,
                        lastSessionAt: last
                    )
                }
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            errorMessage = nil
        } catch {
            worktrees = []
            errorMessage = error.localizedDescription
        }
    }

    func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Pick the folder that contains your worktrees"
        if panel.runModal() == .OK, let url = panel.url {
            rootPath = url.path
        }
    }

    func launchClaude(
        in worktree: Worktree,
        resumeSessionId: String? = nil,
        newSessionName: String? = nil
    ) {
        var claudeCmd = "claude"
        if let id = resumeSessionId {
            claudeCmd += " --resume \(singleQuote(id))"
        } else if let name = newSessionName?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !name.isEmpty {
            claudeCmd += " -n \(singleQuote(name))"
        }
        let command = "cd \(singleQuote(worktree.url.path)) && clear && \(claudeCmd)"
        let source = """
        tell application "Terminal"
            activate
            do script "\(escapeForAppleScript(command))"
        end tell
        """
        var err: NSDictionary?
        if let script = NSAppleScript(source: source) {
            script.executeAndReturnError(&err)
            if let err = err {
                errorMessage = "AppleScript failed: \(err[NSAppleScript.errorMessage] ?? err)"
            }
        }
    }

    func revealInFinder(_ worktree: Worktree) {
        NSWorkspace.shared.activateFileViewerSelecting([worktree.url])
    }

    private func singleQuote(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func escapeForAppleScript(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static func claudeSessionInfo(for dir: URL) -> (count: Int, lastModified: Date?) {
        let sessionDir = ClaudeProjects.sessionDir(for: dir)
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: sessionDir.path, isDirectory: &isDir), isDir.boolValue else {
            return (0, nil)
        }
        guard let entries = try? fm.contentsOfDirectory(
            at: sessionDir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return (0, nil) }
        let sessions = entries.filter { $0.pathExtension == "jsonl" }
        let latest = sessions.compactMap {
            try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        }.max()
        return (sessions.count, latest)
    }
}
