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
    private static let sourceRepoKey = "SparkPlug.defaultSourceRepo"
    private static let setupCmdKey = "SparkPlug.setupCommandTemplate"
    static let defaultSetupCommand = "./scripts/mpro-worktree.sh {ticket} {brief} {base}"

    @Published var rootPath: String {
        didSet {
            UserDefaults.standard.set(rootPath, forKey: Self.rootKey)
            scan()
        }
    }
    /// Repo new worktrees branch from. Defaults the New Worktree sheet; the user
    /// can override per-creation.
    @Published var defaultSourceRepo: String {
        didSet { UserDefaults.standard.set(defaultSourceRepo, forKey: Self.sourceRepoKey) }
    }
    /// Shell command that creates + provisions the worktree, run in the source
    /// repo. Placeholders {ticket} {brief} {base} are substituted (single-quoted).
    @Published var setupCommandTemplate: String {
        didSet { UserDefaults.standard.set(setupCommandTemplate, forKey: Self.setupCmdKey) }
    }
    @Published private(set) var worktrees: [Worktree] = []
    @Published var errorMessage: String?

    init() {
        let defaultPath = ("~/worktrees" as NSString).expandingTildeInPath
        self.rootPath = UserDefaults.standard.string(forKey: Self.rootKey) ?? defaultPath
        self.defaultSourceRepo = UserDefaults.standard.string(forKey: Self.sourceRepoKey) ?? ""
        self.setupCommandTemplate = UserDefaults.standard.string(forKey: Self.setupCmdKey)
            ?? Self.defaultSetupCommand
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

    /// Folder picker for the source repo. Returns the chosen path (nil if
    /// cancelled) so callers decide whether to also persist it as the default.
    func pickSourceRepo(startingAt current: String) -> String? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Pick the source repository to branch worktrees from"
        let expanded = (current as NSString).expandingTildeInPath
        if !expanded.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: expanded)
        }
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return url.path
    }

    /// Creates a worktree by running the setup command in `sourceRepo`, then
    /// launches Claude *inside* the new worktree so its transcript is associated
    /// with the worktree (not the source repo). All chained in one Terminal.
    func createWorktree(
        sourceRepo: String,
        ticket: String,
        briefName: String,
        baseBranch: String
    ) {
        let repo = (sourceRepo as NSString).expandingTildeInPath
        let setupCmd = setupCommandTemplate
            .replacingOccurrences(of: "{ticket}", with: singleQuote(ticket))
            .replacingOccurrences(of: "{brief}", with: singleQuote(briefName))
            .replacingOccurrences(of: "{base}", with: singleQuote(baseBranch))
        // Mirrors the setup script's target: <root>/<ticket>_<BriefName>.
        let rootExpanded = (rootPath as NSString).expandingTildeInPath
        let worktreePath = (rootExpanded as NSString)
            .appendingPathComponent("\(ticket)_\(briefName)")
        let command = "cd \(singleQuote(repo)) && \(setupCmd) "
            + "&& cd \(singleQuote(worktreePath)) && clear && claude"
        runInTerminal(command)
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
        runInTerminal(command)
    }

    /// Runs a shell command in a new Terminal window via AppleScript.
    private func runInTerminal(_ command: String) {
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

    func openInFinder(_ worktree: Worktree) {
        NSWorkspace.shared.open(worktree.url)
    }

    func revealSessionInFinder(_ session: ClaudeSession) {
        NSWorkspace.shared.activateFileViewerSelecting([session.fileURL])
    }

    /// Permanently deletes a session's `.jsonl` and its companion subagent
    /// directory (if any). Refuses to act on a live session.
    @discardableResult
    func deleteSession(_ session: ClaudeSession) -> Bool {
        guard !session.isLive else {
            errorMessage = "Cannot delete a live session — quit Claude first."
            return false
        }
        let fm = FileManager.default
        do {
            try fm.removeItem(at: session.fileURL)
            let companion = session.fileURL.deletingLastPathComponent()
                .appendingPathComponent(session.id, isDirectory: true)
            if fm.fileExists(atPath: companion.path) {
                try? fm.removeItem(at: companion)
            }
            scan()
            return true
        } catch {
            errorMessage = "Failed to delete session: \(error.localizedDescription)"
            return false
        }
    }

    /// Permanently removes a worktree. For a real git worktree this runs
    /// `git worktree remove --force` (so the main repo's metadata is cleaned
    /// up too); for a plain folder it deletes the directory. Refuses if a live
    /// session is running in it. Claude transcripts under ~/.claude are left
    /// intact — delete those separately if desired.
    @discardableResult
    func deleteWorktree(_ wt: Worktree) -> Bool {
        if ClaudeProjects.sessions(for: wt.url).contains(where: { $0.isLive }) {
            errorMessage = "Cannot delete — a live Claude session is running here. Quit it first."
            return false
        }
        let fm = FileManager.default
        var gitIsDir: ObjCBool = false
        let gitPath = wt.url.appendingPathComponent(".git").path
        let hasGit = fm.fileExists(atPath: gitPath, isDirectory: &gitIsDir)
        // A linked worktree has a `.git` *file* (pointer); a full repo has a dir.
        let isLinkedWorktree = hasGit && !gitIsDir.boolValue

        if isLinkedWorktree {
            // git refuses to remove the worktree containing its own cwd, so run
            // the command from the main working tree.
            let common = runGit(["-C", wt.url.path, "rev-parse",
                                  "--path-format=absolute", "--git-common-dir"])
            guard common.status == 0, !common.output.isEmpty else {
                errorMessage = "Couldn't resolve the git repo for \(wt.name)."
                return false
            }
            let mainTree = URL(fileURLWithPath: common.output)  // …/.git
                .deletingLastPathComponent().path
            let res = runGit(["-C", mainTree, "worktree", "remove", "--force", wt.url.path])
            guard res.status == 0 else {
                errorMessage = "git worktree remove failed: \(res.output)"
                return false
            }
            runGit(["-C", mainTree, "worktree", "prune"])
            scan()
            return true
        } else {
            do {
                try fm.removeItem(at: wt.url)
                scan()
                return true
            } catch {
                errorMessage = "Failed to delete worktree: \(error.localizedDescription)"
                return false
            }
        }
    }

    /// Runs git (Apple's CLT shim) and returns its exit status + combined output.
    @discardableResult
    private func runGit(_ args: [String]) -> (status: Int32, output: String) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        proc.arguments = args
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        do {
            try proc.run()
            proc.waitUntilExit()
        } catch {
            return (-1, error.localizedDescription)
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let out = (String(data: data, encoding: .utf8) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (proc.terminationStatus, out)
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
