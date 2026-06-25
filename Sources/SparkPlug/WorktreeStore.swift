import SwiftUI
import AppKit

struct Worktree: Identifiable, Hashable {
    /// Group name for directories that aren't git worktrees or repos.
    static let otherProjectName = "Other"

    let id = UUID()
    let name: String
    let url: URL
    let isGitRepo: Bool
    /// Source project this worktree belongs to: the main repo's folder name
    /// for a linked worktree, the folder's own name for a full clone, or
    /// `otherProjectName` for plain directories.
    let projectName: String
    /// Path of the main repository (nil when not resolvable).
    let projectPath: String?
    /// Parsed at scan time (newest first) so view bodies never touch disk.
    let sessions: [ClaudeSession]

    var sessionCount: Int { sessions.count }
    var lastSessionAt: Date? { sessions.first?.lastModified }
    var hasClaudeSession: Bool { !sessions.isEmpty }
}

/// One section in the list: a base repo (registered and/or discovered from
/// worktree `.git` pointers) and the worktrees that belong to it.
struct ProjectGroup: Identifiable {
    let name: String
    /// Main repo path; nil only for the trailing "Other" group.
    let path: String?
    let isRegistered: Bool
    let worktrees: [Worktree]
    var id: String { path ?? name }
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
    private static let reposKey = "SparkPlug.registeredRepos"
    static let defaultSetupCommand = "./scripts/setup-worktree.sh {ticket} {brief} {base}"

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
    /// Base repos the user has added; they appear as (possibly empty) project
    /// groups. Repos are also discovered from existing worktrees' `.git`
    /// pointers, so this list only needs to carry repos with no worktrees yet.
    @Published var registeredRepos: [String] {
        didSet { UserDefaults.standard.set(registeredRepos, forKey: Self.reposKey) }
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
        self.registeredRepos = UserDefaults.standard.stringArray(forKey: Self.reposKey) ?? []
        scan()
    }

    /// Sections for the list: every registered repo plus every repo discovered
    /// from worktrees, alphabetical, with non-git folders under "Other" last.
    var projectGroups: [ProjectGroup] {
        var byPath: [String: [Worktree]] = [:]
        var others: [Worktree] = []
        for wt in worktrees {
            if let p = wt.projectPath {
                byPath[p, default: []].append(wt)
            } else {
                others.append(wt)
            }
        }
        let registered = Set(registeredRepos)
        var groups = Set(byPath.keys).union(registered).map { path in
            ProjectGroup(
                name: URL(fileURLWithPath: path).lastPathComponent,
                path: path,
                isRegistered: registered.contains(path),
                worktrees: byPath[path] ?? []
            )
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        if !others.isEmpty {
            groups.append(ProjectGroup(
                name: Worktree.otherProjectName, path: nil,
                isRegistered: false, worktrees: others))
        }
        return groups
    }

    /// Folder picker that registers a base repo as a project group.
    func addRepo() {
        // The popover deactivates this accessory app as it closes, and an
        // inactive app's open panel renders but ignores row selection.
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Add"
        panel.message = "Pick a base repository to manage worktrees for"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard FileManager.default.fileExists(
            atPath: url.appendingPathComponent(".git").path) else {
            errorMessage = "\(url.lastPathComponent) doesn't look like a git repository."
            return
        }
        if !registeredRepos.contains(url.path) {
            registeredRepos.append(url.path)
        }
    }

    /// Forgets a registered repo. Disk is untouched; a repo with worktrees on
    /// disk keeps appearing via discovery.
    func removeRepo(_ path: String) {
        registeredRepos.removeAll { $0 == path }
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
                    let project = Self.projectInfo(for: dir)
                    return Worktree(
                        name: dir.lastPathComponent,
                        url: dir,
                        isGitRepo: fm.fileExists(atPath: gitPath),
                        projectName: project.name,
                        projectPath: project.path,
                        sessions: ClaudeProjects.sessions(for: dir)
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
        if let path = Self.promptForFolder(message: "Pick the folder that contains your worktrees") {
            rootPath = path
        }
    }

    /// Shows a directory-only open panel and returns the chosen path, if any.
    static func promptForFolder(message: String) -> String? {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = message
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
        let dirName = worktreeFolderName(repo: repo, ticket: ticket, brief: briefName)
        let rootExpanded = (rootPath as NSString).expandingTildeInPath
        let worktreePath = (rootExpanded as NSString).appendingPathComponent(dirName)
        let useScript = willUseSetupScript(repo: repo, ticket: ticket)
        let setupCmd: String
        if useScript {
            setupCmd = setupCommandTemplate
                .replacingOccurrences(of: "{ticket}", with: singleQuote(ticket))
                .replacingOccurrences(of: "{brief}", with: singleQuote(briefName))
                .replacingOccurrences(of: "{base}", with: singleQuote(baseBranch))
        } else {
            setupCmd = "git worktree add -b \(singleQuote(dirName)) "
                + "\(singleQuote(worktreePath)) \(singleQuote(baseBranch))"
        }
        // Provision from the worktree that has the base branch checked out, not
        // the source repo: the setup script and the tools it invokes must come
        // from the same commit the new worktree is branched from. Falls back to
        // the source repo when the base isn't checked out anywhere.
        let scriptDir = useScript
            ? provisioningDir(sourceRepo: repo, baseBranch: baseBranch)
            : repo
        // Folder, tmux window, and Claude session share one label so a
        // running session is identifiable from any of them. The script path
        // names its own folder (ticket_brief), so the label adds the project
        // prefix only where the folder couldn't carry it.
        let repoName = URL(fileURLWithPath: repo).lastPathComponent
        let label = dirName.hasPrefix("\(repoName)_") ? dirName : "\(repoName)_\(dirName)"
        let command = "cd \(singleQuote(scriptDir)) && \(setupCmd) "
            + "&& cd \(singleQuote(worktreePath)) && clear "
            + "&& claude -n \(singleQuote(label))"
        // Bring the base branch up to date with its remote *before* cutting the
        // worktree, off the main actor so the network I/O never freezes the UI.
        // A clean refresh is silent; a stash reapply that conflicts surfaces via
        // `errorMessage` (the launched terminal can't report back — `clear` and
        // Claude take the screen). Either way the worktree is still created.
        Task {
            if let warning = await Task.detached(priority: .userInitiated, operation: {
                Self.refreshBase(repo: repo, base: baseBranch)
            }).value {
                self.errorMessage = warning
            }
            self.launch(command, windowName: label, choice: tmuxChoice)
        }
    }

    /// Brings `base` up to date with its remote in `repo`. Run off the main
    /// actor — it performs network I/O. When `base` is the checked-out branch,
    /// uncommitted work (tracked + untracked) is stashed across a fast-forward
    /// pull and reapplied; when it isn't, the branch ref is fast-forwarded from
    /// the remote directly. Returns a user-facing warning when the stash can't
    /// be reapplied cleanly (the work is left in the tree *and* kept on the
    /// stash, never dropped), otherwise nil. Every git step is best-effort: an
    /// offline remote or a diverged branch is not reported and never blocks
    /// creation.
    nonisolated private static func refreshBase(repo: String, base: String) -> String? {
        @discardableResult
        func git(_ args: [String]) -> (status: Int32, output: String) {
            runProcessSync("/usr/bin/git", ["-C", repo] + args)
        }
        let head = git(["symbolic-ref", "--short", "-q", "HEAD"])
        guard head.status == 0, head.output == base else {
            // Base isn't checked out: no working tree to preserve. Fast-forward
            // its local ref straight from the remote.
            git(["fetch", "origin"])
            git(["fetch", "origin", "\(base):\(base)"])
            return nil
        }
        // `stash push` exits non-zero when there's nothing to stash.
        let didStash = git(["stash", "push", "-u", "-m", "spark-plug-autostash"]).status == 0
        git(["pull", "--ff-only"])
        guard didStash else { return nil }
        if git(["stash", "pop"]).status != 0 {
            let name = URL(fileURLWithPath: repo).lastPathComponent
            return "Updated \(base), but reapplying your uncommitted changes in "
                + "\(name) hit a conflict. They're preserved in the working tree "
                + "and kept on the stash — open \(name) and resolve them "
                + "(then `git stash drop`) before its next worktree."
        }
        return nil
    }

    /// Final folder/branch name for a new worktree. When the setup script
    /// will run, its own convention (`<ticket>_<brief>`) is mirrored; the
    /// plain `git worktree add` path prefixes the project name.
    func worktreeFolderName(repo: String, ticket: String, brief: String) -> String {
        let base = ticket.isEmpty ? brief : "\(ticket)_\(brief)"
        if willUseSetupScript(repo: repo, ticket: ticket) { return base }
        let repoName = URL(fileURLWithPath: repo).lastPathComponent
        return base.hasPrefix("\(repoName)_") ? base : "\(repoName)_\(base)"
    }

    /// Project-header "New Worktree": just a name and an optional ticket —
    /// the name is sanitised and, unless a `baseBranch` is supplied (e.g. the
    /// branch of an existing worktree the user chose to fork from), the base
    /// branch is auto-picked. Returns a user-facing problem (shown inline in
    /// the card) instead of launching when the name is invalid or its branch
    /// already exists.
    @discardableResult
    func createWorktree(
        repoPath: String,
        ticket: String,
        name: String,
        baseBranch: String? = nil
    ) -> String? {
        let brief = Self.sanitized(name)
        let tick = ticket.trimmingCharacters(in: .whitespacesAndNewlines)
        let dirName = worktreeFolderName(repo: repoPath, ticket: tick, brief: brief)
        if let problem = worktreeNameProblem(dirName) { return problem }
        if localBranchExists(in: repoPath, branch: dirName) {
            return "Branch “\(dirName)” already exists — pick another name or delete that branch first."
        }
        createWorktree(
            sourceRepo: repoPath,
            ticket: tick,
            briefName: brief,
            baseBranch: baseBranch ?? defaultBaseBranch(in: repoPath)
        )
        return nil
    }

    /// develop → main → master → whatever HEAD points at.
    func defaultBaseBranch(in repoPath: String) -> String {
        for candidate in ["develop", "main", "master"]
        where branchExists(in: repoPath, branch: candidate) {
            return candidate
        }
        let head = runGit(["-C", repoPath, "symbolic-ref", "--short", "HEAD"])
        return head.status == 0 && !head.output.isEmpty ? head.output : "main"
    }

    /// "Import/Export Groups" → "Import_Export_Groups" — a name safe for a
    /// directory and a git branch. Dashes survive so repo names keep theirs.
    static func sanitized(_ s: String) -> String {
        let words = s.split { !$0.isLetter && !$0.isNumber && $0 != "-" }
        return words.isEmpty ? "Session" : words.joined(separator: "_")
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

    /// The branch checked out in a worktree (its HEAD), or nil when the head
    /// is detached or the path isn't a git worktree. Used to offer an existing
    /// worktree as the fork point for a new one.
    func currentBranch(in path: String) -> String? {
        let res = runGit(["-C", path, "symbolic-ref", "--short", "HEAD"])
        return res.status == 0 && !res.output.isEmpty ? res.output : nil
    }

    /// Whether `branch` resolves to a commit in the repo (local branch,
    /// remote-tracking branch, tag, or SHA).
    func branchExists(in repoPath: String, branch: String) -> Bool {
        runGit(["-C", repoPath, "rev-parse", "--verify", "--quiet",
                branch + "^{commit}"]).status == 0
    }

    /// Why `name` won't work as the worktree's branch/folder name, or nil
    /// when it's fine. Slashes are rejected even though git allows them in
    /// branches, because the name doubles as a single directory component.
    func worktreeNameProblem(_ name: String) -> String? {
        let suggestion = Self.sanitized(name)
        if name.contains("/") {
            return "“\(name)” can't contain “/” — it's also the folder name. Try “\(suggestion)”."
        }
        if name.contains(where: \.isWhitespace) {
            return "Spaces aren't valid in a branch name. Try “\(suggestion)”."
        }
        if runGit(["check-ref-format", "--branch", name]).status != 0 {
            return "“\(name)” isn't a valid git branch name. Try “\(suggestion)”."
        }
        return nil
    }

    /// Whether a *local* branch with this exact name exists — used to catch
    /// `git worktree add -b` collisions before launching.
    func localBranchExists(in repoPath: String, branch: String) -> Bool {
        runGit(["-C", repoPath, "show-ref", "--verify", "--quiet",
                "refs/heads/" + branch]).status == 0
    }

    /// Directory the provisioning script should run from: the worktree that has
    /// `baseBranch` checked out, so the script (and the tools it invokes) match
    /// the commit the new worktree is branched from. Falls back to `sourceRepo`
    /// when the base branch isn't checked out in its own worktree, or that
    /// worktree doesn't carry the setup script.
    func provisioningDir(sourceRepo: String, baseBranch: String) -> String {
        guard let dir = worktreeDir(forBranch: baseBranch, in: sourceRepo),
              dir != sourceRepo,
              setupScriptAvailable(in: dir) else {
            return sourceRepo
        }
        return dir
    }

    /// Absolute path of the worktree that currently has `branch` checked out, or
    /// nil when none does (e.g. a remote-tracking or unborn branch). Parses
    /// `git worktree list --porcelain`, matching `branch refs/heads/<branch>`.
    func worktreeDir(forBranch branch: String, in repoPath: String) -> String? {
        let res = runGit(["-C", repoPath, "worktree", "list", "--porcelain"])
        guard res.status == 0 else { return nil }
        var currentPath: String?
        for line in res.output.components(separatedBy: "\n") {
            if line.hasPrefix("worktree ") {
                currentPath = String(line.dropFirst("worktree ".count))
            } else if line == "branch refs/heads/\(branch)" {
                return currentPath
            }
        }
        return nil
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
        resumeTitle: String? = nil,
        newSessionName: String? = nil
    ) {
        var claudeCmd = "claude"
        var sessionLabel: String?
        if let id = resumeSessionId {
            claudeCmd += " --resume \(singleQuote(id))"
            sessionLabel = resumeTitle
        } else if let name = newSessionName?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !name.isEmpty {
            claudeCmd += " -n \(singleQuote(name))"
            sessionLabel = name
        }
        let command = "cd \(singleQuote(worktree.url.path)) && clear && \(claudeCmd)"
        launch(command, windowName: windowName(worktree: worktree.name, session: sessionLabel))
    }

    /// "worktree — session" so several sessions in the same worktree stay
    /// distinguishable in the tmux status bar (`-n` pins the name, so tmux
    /// never renames it later); just the worktree name when there's no label.
    private func windowName(worktree: String, session: String?) -> String {
        guard let session = session?.trimmingCharacters(in: .whitespacesAndNewlines),
              !session.isEmpty else { return worktree }
        let short = session.count > 24 ? String(session.prefix(24)) + "…" : session
        return "\(worktree) — \(short)"
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
    nonisolated private static func debugLog(_ message: String) {
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
        Self.runProcessSync(path, args)
    }

    /// Actor-agnostic process runner so the background base-refresh can spawn
    /// git off the main actor. Blocks the calling thread until the process exits.
    nonisolated private static func runProcessSync(
        _ path: String, _ args: [String]
    ) -> (status: Int32, output: String) {
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
            debugLog("\(path) \(args.joined(separator: " ")) → spawn failed: \(error.localizedDescription)")
            return (-1, error.localizedDescription)
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let out = (String(data: data, encoding: .utf8) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        debugLog("\(path) \(args.joined(separator: " ")) → \(proc.terminationStatus) \(out)")
        return (proc.terminationStatus, out)
    }

    private func singleQuote(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func escapeForAppleScript(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// Resolves which source project a directory belongs to without spawning
    /// git: a linked worktree's `.git` *file* contains
    /// `gitdir: <repo>/.git/worktrees/<name>`, so the repo folder is three
    /// components up. A full clone (`.git` directory) is its own project.
    private static func projectInfo(for dir: URL) -> (name: String, path: String?) {
        let fm = FileManager.default
        let gitURL = dir.appendingPathComponent(".git")
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: gitURL.path, isDirectory: &isDir) else {
            return (Worktree.otherProjectName, nil)
        }
        if isDir.boolValue {
            return (dir.lastPathComponent, dir.path)
        }
        guard let contents = try? String(contentsOf: gitURL, encoding: .utf8),
              let line = contents.split(whereSeparator: \.isNewline)
                  .first(where: { $0.hasPrefix("gitdir:") })
        else { return (Worktree.otherProjectName, nil) }
        let gitdir = line.dropFirst("gitdir:".count)
            .trimmingCharacters(in: .whitespaces)
        // gitdir may be relative to the worktree directory.
        let gitdirURL = URL(fileURLWithPath: gitdir,
                            relativeTo: dir).standardizedFileURL
        let worktreesDir = gitdirURL.deletingLastPathComponent()
        let dotGit = worktreesDir.deletingLastPathComponent()
        guard worktreesDir.lastPathComponent == "worktrees",
              dotGit.lastPathComponent == ".git"
        else { return (Worktree.otherProjectName, nil) }
        let repo = dotGit.deletingLastPathComponent()
        return (repo.lastPathComponent, repo.path)
    }

}
