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

/// A launch waiting on the user to pick which tmux session to put it in.
struct PendingTmuxLaunch: Identifiable {
    let id = UUID()
    let command: String
    let windowName: String
    let sessionNames: [String]
}

/// Where a launch should land in tmux. `.automatic` reuses a sole session,
/// creates one if none exist, or defers to the user when several are running.
enum TmuxChoice: Hashable {
    case automatic
    case newSession
    case session(String)
}

@MainActor
final class WorktreeStore: ObservableObject {
    /// Single store shared by the window and menubar views so state (and
    /// cross-view requests like `newWorktreeRequested`) stays in sync.
    static let shared = WorktreeStore()

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
    /// Set when multiple tmux sessions exist and the user must choose one.
    @Published var pendingTmuxLaunch: PendingTmuxLaunch?

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

    /// Creates a worktree, then launches Claude *inside* it so its transcript
    /// is associated with the worktree (not the source repo). Uses the repo's
    /// setup command when it applies (see `willUseSetupScript`), otherwise a
    /// plain `git worktree add`. All chained in one shell.
    func createWorktree(
        sourceRepo: String,
        ticket: String,
        briefName: String,
        baseBranch: String,
        tmuxChoice: TmuxChoice = .automatic
    ) {
        let repo = (sourceRepo as NSString).expandingTildeInPath
        // Mirrors the setup script's target: <root>/<ticket>_<BriefName>,
        // or just <BriefName> when there's no ticket.
        let dirName = ticket.isEmpty ? briefName : "\(ticket)_\(briefName)"
        let rootExpanded = (rootPath as NSString).expandingTildeInPath
        let worktreePath = (rootExpanded as NSString).appendingPathComponent(dirName)
        let setupCmd: String
        if willUseSetupScript(repo: repo, ticket: ticket) {
            setupCmd = setupCommandTemplate
                .replacingOccurrences(of: "{ticket}", with: singleQuote(ticket))
                .replacingOccurrences(of: "{brief}", with: singleQuote(briefName))
                .replacingOccurrences(of: "{base}", with: singleQuote(baseBranch))
        } else {
            setupCmd = "git worktree add -b \(singleQuote(dirName)) "
                + "\(singleQuote(worktreePath)) \(singleQuote(baseBranch))"
        }
        let command = "cd \(singleQuote(repo)) && \(setupCmd) "
            + "&& cd \(singleQuote(worktreePath)) && clear && claude"
        launch(command, windowName: dirName, choice: tmuxChoice)
    }

    /// Whether the setup command will be used for `repo`: its executable must
    /// exist there, and a ticket must be supplied if the template needs one.
    func willUseSetupScript(repo: String, ticket: String) -> Bool {
        guard !setupCommandTemplate.contains("{ticket}") || !ticket.isEmpty else {
            return false
        }
        return setupScriptAvailable(in: repo)
    }

    /// Local branch names followed by remote-tracking ones (e.g.
    /// `origin/develop`), deduplicated, `origin/HEAD` dropped. Empty when
    /// `repoPath` isn't a git repo.
    func branches(in repoPath: String) -> [String] {
        guard !repoPath.isEmpty else { return [] }
        let res = runGit(["-C", repoPath, "for-each-ref",
                          "--format=%(refname:short)", "refs/heads", "refs/remotes"])
        guard res.status == 0, !res.output.isEmpty else { return [] }
        var seen = Set<String>()
        return res.output.components(separatedBy: "\n")
            .filter { !$0.hasSuffix("/HEAD") }
            .filter { seen.insert($0).inserted }
    }

    /// Whether `branch` resolves to a commit in the repo (local branch,
    /// remote-tracking branch, tag, or SHA).
    func branchExists(in repoPath: String, branch: String) -> Bool {
        runGit(["-C", repoPath, "rev-parse", "--verify", "--quiet",
                branch + "^{commit}"]).status == 0
    }

    /// Whether a *local* branch with this exact name exists — used to catch
    /// `git worktree add -b` collisions before launching.
    func localBranchExists(in repoPath: String, branch: String) -> Bool {
        runGit(["-C", repoPath, "show-ref", "--verify", "--quiet",
                "refs/heads/" + branch]).status == 0
    }

    /// True when the setup command's executable can be found: an absolute (or
    /// tilde) path is checked directly, a relative path is resolved against
    /// the repo, and a bare command is assumed to be on PATH.
    func setupScriptAvailable(in repoPath: String) -> Bool {
        guard let first = setupCommandTemplate
            .split(separator: " ", omittingEmptySubsequences: true).first else {
            return false
        }
        let token = (String(first) as NSString).expandingTildeInPath
        let fm = FileManager.default
        if token.hasPrefix("/") {
            return fm.isExecutableFile(atPath: token)
        }
        if token.contains("/") {
            return fm.isExecutableFile(
                atPath: (repoPath as NSString).appendingPathComponent(token))
        }
        return true
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
        launch(command, windowName: worktree.name)
    }

    // MARK: - tmux

    /// Launches `command` in tmux when available: reuses the only running
    /// session, creates one if none exist, or asks the user to pick when
    /// several are running. Falls back to a plain Terminal window without tmux.
    private func launch(_ command: String, windowName: String, choice: TmuxChoice = .automatic) {
        guard tmuxPath != nil else {
            runInTerminal(command)
            return
        }
        switch choice {
        case .session(let name):
            launchInTmux(command, windowName: windowName, session: name)
        case .newSession:
            launchInTmux(command, windowName: windowName, session: nil)
        case .automatic:
            let sessions = tmuxSessionNames()
            if sessions.count > 1 {
                pendingTmuxLaunch = PendingTmuxLaunch(
                    command: command, windowName: windowName, sessionNames: sessions)
            } else {
                launchInTmux(command, windowName: windowName, session: sessions.first)
            }
        }
    }

    /// Resolves a pending launch with the chosen session (nil = new session).
    func completePendingLaunch(session: String?) {
        guard let pending = pendingTmuxLaunch else { return }
        pendingTmuxLaunch = nil
        launchInTmux(pending.command, windowName: pending.windowName, session: session)
    }

    /// Opens a new tmux window in `session` (or a fresh session when nil) and
    /// types `command` into its login shell — typing rather than passing the
    /// command directly so the user's PATH (claude, nvm, etc.) is in effect.
    private func launchInTmux(_ command: String, windowName: String, session: String?) {
        guard let tmux = tmuxPath else {
            runInTerminal(command)
            return
        }
        let name = windowName.isEmpty ? "claude" : windowName
        let sessionName: String
        let created: (status: Int32, output: String)
        var isNewSession = false
        if let session {
            sessionName = session
            created = runProcess(tmux, ["new-window", "-t", "=\(session):",
                                        "-n", name, "-P", "-F", "#{window_id}"])
        } else {
            sessionName = uniqueSessionName()
            created = runProcess(tmux, ["new-session", "-d", "-s", sessionName,
                                        "-n", name, "-P", "-F", "#{window_id}"])
            isNewSession = true
        }
        guard created.status == 0, !created.output.isEmpty else {
            errorMessage = "tmux failed: \(created.output)"
            return
        }
        let windowId = created.output
        runProcess(tmux, ["send-keys", "-t", windowId, "-l", command])
        runProcess(tmux, ["send-keys", "-t", windowId, "Enter"])
        // If nothing is viewing the session, attach it in a Terminal window.
        if isNewSession || !isSessionAttached(sessionName) {
            runInTerminal("\(tmux) attach -t \(singleQuote(sessionName))")
        }
    }

    /// Names of running tmux sessions ([] when tmux/server isn't running).
    func tmuxSessionNames() -> [String] {
        guard let tmux = tmuxPath else { return [] }
        let res = runProcess(tmux, ["list-sessions", "-F", "#{session_name}"])
        guard res.status == 0, !res.output.isEmpty else { return [] }
        return res.output.components(separatedBy: "\n")
    }

    private func isSessionAttached(_ name: String) -> Bool {
        guard let tmux = tmuxPath else { return false }
        let res = runProcess(tmux, ["display-message", "-p", "-t", "=\(name):",
                                    "#{session_attached}"])
        return res.status == 0 && (Int(res.output) ?? 0) > 0
    }

    private func uniqueSessionName() -> String {
        let existing = Set(tmuxSessionNames())
        if !existing.contains("spark-plug") { return "spark-plug" }
        var i = 2
        while existing.contains("spark-plug-\(i)") { i += 1 }
        return "spark-plug-\(i)"
    }

    private var tmuxPath: String? {
        ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux",
         "/opt/local/bin/tmux", "/usr/bin/tmux"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
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
        Self.debugLog("deleteWorktree: \(wt.url.path)")
        if ClaudeProjects.sessions(for: wt.url).contains(where: { $0.isLive }) {
            Self.debugLog("deleteWorktree blocked: live session in \(wt.name)")
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
            // Capture the checked-out branch before the worktree disappears.
            let head = runGit(["-C", wt.url.path, "symbolic-ref", "--short", "HEAD"])
            let res = runGit(["-C", mainTree, "worktree", "remove", "--force", wt.url.path])
            guard res.status == 0 else {
                errorMessage = "git worktree remove failed: \(res.output)"
                return false
            }
            runGit(["-C", mainTree, "worktree", "prune"])
            // `git worktree remove` leaves the branch behind, which then
            // blocks recreating a worktree with the same name. Only delete it
            // when it matches the folder name (our naming convention) so a
            // shared branch checked out here by hand is never torched.
            if head.status == 0, head.output == wt.name {
                runGit(["-C", mainTree, "branch", "-D", head.output])
            }
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
        runProcess("/usr/bin/git", args)
    }

    /// Appends to ~/Library/Logs/SparkPlug.log. Plain file because os_log
    /// entries weren't retrievable via `log show` on this system.
    private static func debugLog(_ message: String) {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/SparkPlug.log")
        let stamp = ISO8601DateFormatter().string(from: Date())
        guard let data = "[\(stamp)] \(message)\n".data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
    }

    /// Runs an executable and returns its exit status + combined, trimmed output.
    @discardableResult
    private func runProcess(_ path: String, _ args: [String]) -> (status: Int32, output: String) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)
        proc.arguments = args
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        do {
            try proc.run()
            proc.waitUntilExit()
        } catch {
            Self.debugLog("\(path) \(args.joined(separator: " ")) → spawn failed: \(error.localizedDescription)")
            return (-1, error.localizedDescription)
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let out = (String(data: data, encoding: .utf8) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        Self.debugLog("\(path) \(args.joined(separator: " ")) → \(proc.terminationStatus) \(out)")
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
