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
    /// Merged across every agent, each session tagged with its own `agent`.
    let sessions: [AgentSession]

    var sessionCount: Int { sessions.count }
    var lastSessionAt: Date? { sessions.first?.lastModified }
    var hasSessions: Bool { !sessions.isEmpty }
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

/// Terminal multiplexer Spark Plug launches Claude sessions into. Persisted in
/// UserDefaults; `.tmux` is the default so existing installs are unchanged.
enum Multiplexer: String, CaseIterable, Identifiable {
    case tmux
    case herdr

    var id: String { rawValue }

    /// User-facing name — tmux is lowercased by convention; Herdr is a product.
    var displayName: String {
        switch self {
        case .tmux: return "tmux"
        case .herdr: return "Herdr"
        }
    }

    /// What this multiplexer calls the container a launch opens into — a tmux
    /// "window" vs a Herdr "workspace" — used in the UI's preview copy.
    var windowNoun: String {
        switch self {
        case .tmux: return "window"
        case .herdr: return "workspace"
        }
    }
}

/// A launch waiting on the user to pick which session to put it in. Either
/// multiplexer surfaces this when several sessions are running at once.
struct PendingSessionLaunch: Identifiable {
    let id = UUID()
    let command: String
    let windowName: String
    let sessionNames: [String]
}

/// Where a launch should land. `.automatic` reuses a sole running session,
/// starts one if none exist, or defers to the user when several are running.
enum SessionChoice: Hashable {
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
    private static let postStartGlobalKey = "SparkPlug.postStartScriptGlobal"
    private static let postStartByRepoKey = "SparkPlug.postStartScriptByRepo"
    private static let reposKey = "SparkPlug.registeredRepos"
    private static let multiplexerKey = "SparkPlug.multiplexer"
    private static let openClaudeKey = "SparkPlug.openClaudeOnStartByRepo"
    private static let openClaudeGlobalKey = "SparkPlug.openClaudeOnStartGlobal"
    private static let agentKey = "SparkPlug.defaultAgent"
    private static let agentByRepoKey = "SparkPlug.agentByRepo"
    private static let agentByWorktreeKey = "SparkPlug.agentByWorktree"
    static let defaultSetupCommand = "./scripts/setup-worktree.sh {ticket} {brief} {base}"
    /// The global default's initial value: create-and-launch Claude, the
    /// behaviour before the setting existed.
    static let defaultOpenClaudeOnStart = true
    /// The post-start script's initial default: empty, i.e. run nothing, so
    /// existing installs are unchanged.
    static let defaultPostStartScript = ""

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
    /// Global default (the root of the Global → Repo → Worktree chain) for the
    /// script run *inside* a freshly created worktree, after provisioning and
    /// before the agent launches. Empty means run nothing. Placeholders
    /// {ticket} {brief} {base} are substituted verbatim (unquoted) so they can
    /// be embedded in the user's own quoting — e.g. `claude -n "{ticket}-{brief}"`.
    @Published var postStartScriptGlobal: String {
        didSet { UserDefaults.standard.set(postStartScriptGlobal, forKey: Self.postStartGlobalKey) }
    }
    /// Per-repo *override* of the global post-start script, keyed by repo path.
    /// A missing entry means the repo inherits the global value; a present entry
    /// (even empty) overrides it. Read via `repoPostStartOverride(forRepo:)`,
    /// resolved via `postStartScript(forRepo:)`.
    @Published private var postStartScriptByRepo: [String: String]
    /// Base repos the user has added; they appear as (possibly empty) project
    /// groups. Repos are also discovered from existing worktrees' `.git`
    /// pointers, so this list only needs to carry repos with no worktrees yet.
    @Published var registeredRepos: [String] {
        didSet { UserDefaults.standard.set(registeredRepos, forKey: Self.reposKey) }
    }
    /// Which terminal multiplexer new Claude sessions open into.
    @Published var multiplexer: Multiplexer {
        didSet { UserDefaults.standard.set(multiplexer.rawValue, forKey: Self.multiplexerKey) }
    }
    /// Global default (the root of the Global → Repo → Worktree chain) for
    /// whether creating a worktree auto-launches Claude vs. leaving a ready shell.
    @Published var openClaudeOnStartGlobal: Bool {
        didSet { UserDefaults.standard.set(openClaudeOnStartGlobal, forKey: Self.openClaudeGlobalKey) }
    }
    /// Per-repo *override* of the global default, keyed by repo path. A missing
    /// entry means the repo inherits the global value. Read via
    /// `repoOpenClaudeOverride(forRepo:)`, resolved via `openClaudeOnStart(forRepo:)`.
    @Published private var openClaudeOnStartByRepo: [String: Bool]
    /// Global default agent — the root of the Global → Repo → Worktree chain.
    @Published var defaultAgent: Agent {
        didSet { UserDefaults.standard.set(defaultAgent.rawValue, forKey: Self.agentKey) }
    }
    /// Per-repo agent *override*, keyed by repo path; absent = inherit global.
    @Published private var agentByRepo: [String: String]
    /// The agent a specific worktree was created with, keyed by worktree path,
    /// so "New session" and resume keep using it rather than the repo/global
    /// default. Absent for worktrees Spark Plug didn't create (they infer their
    /// agent from existing sessions instead).
    @Published private var agentByWorktree: [String: String]
    @Published private(set) var worktrees: [Worktree] = []
    @Published var errorMessage: String?
    /// Set when multiple sessions are running and the user must choose one.
    @Published var pendingSessionLaunch: PendingSessionLaunch?

    init() {
        let defaultPath = ("~/worktrees" as NSString).expandingTildeInPath
        self.rootPath = UserDefaults.standard.string(forKey: Self.rootKey) ?? defaultPath
        self.defaultSourceRepo = UserDefaults.standard.string(forKey: Self.sourceRepoKey) ?? ""
        self.setupCommandTemplate = UserDefaults.standard.string(forKey: Self.setupCmdKey)
            ?? Self.defaultSetupCommand
        self.postStartScriptGlobal = UserDefaults.standard.string(forKey: Self.postStartGlobalKey)
            ?? Self.defaultPostStartScript
        var postStart: [String: String] = [:]
        for (path, value) in UserDefaults.standard.dictionary(forKey: Self.postStartByRepoKey) ?? [:] {
            if let script = value as? String { postStart[path] = script }
        }
        self.postStartScriptByRepo = postStart
        self.registeredRepos = UserDefaults.standard.stringArray(forKey: Self.reposKey) ?? []
        self.multiplexer = UserDefaults.standard.string(forKey: Self.multiplexerKey)
            .flatMap(Multiplexer.init(rawValue:)) ?? .tmux
        self.openClaudeOnStartGlobal =
            UserDefaults.standard.object(forKey: Self.openClaudeGlobalKey) as? Bool
            ?? Self.defaultOpenClaudeOnStart
        var openClaude: [String: Bool] = [:]
        for (path, value) in UserDefaults.standard.dictionary(forKey: Self.openClaudeKey) ?? [:] {
            if let flag = value as? Bool { openClaude[path] = flag }
        }
        self.openClaudeOnStartByRepo = openClaude
        self.defaultAgent = UserDefaults.standard.string(forKey: Self.agentKey)
            .flatMap(Agent.init(rawValue:)) ?? .claude
        var agentRepos: [String: String] = [:]
        for (path, value) in UserDefaults.standard.dictionary(forKey: Self.agentByRepoKey) ?? [:] {
            if let raw = value as? String { agentRepos[path] = raw }
        }
        self.agentByRepo = agentRepos
        var agentWorktrees: [String: String] = [:]
        for (path, value) in UserDefaults.standard.dictionary(forKey: Self.agentByWorktreeKey) ?? [:] {
            if let raw = value as? String { agentWorktrees[path] = raw }
        }
        self.agentByWorktree = agentWorktrees
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

    /// The repo's explicit override, or nil when it inherits the global default.
    func repoOpenClaudeOverride(forRepo path: String) -> Bool? {
        openClaudeOnStartByRepo[path]
    }

    /// Sets the repo override, or clears it (nil) to inherit the global default.
    func setRepoOpenClaudeOverride(_ value: Bool?, forRepo path: String) {
        if let value {
            openClaudeOnStartByRepo[path] = value
        } else {
            openClaudeOnStartByRepo.removeValue(forKey: path)
        }
        UserDefaults.standard.set(openClaudeOnStartByRepo, forKey: Self.openClaudeKey)
    }

    /// The value a new worktree of `path` starts from — the repo override when
    /// set, otherwise the global default. The per-worktree toggle seeds from this.
    func openClaudeOnStart(forRepo path: String) -> Bool {
        openClaudeOnStartByRepo[path] ?? openClaudeOnStartGlobal
    }

    /// The repo's explicit post-start script, or nil when it inherits the global.
    func repoPostStartOverride(forRepo path: String) -> String? {
        postStartScriptByRepo[path]
    }

    /// Sets the repo's post-start override, or clears it (nil) to inherit global.
    func setRepoPostStartOverride(_ value: String?, forRepo path: String) {
        if let value {
            postStartScriptByRepo[path] = value
        } else {
            postStartScriptByRepo.removeValue(forKey: path)
        }
        UserDefaults.standard.set(postStartScriptByRepo, forKey: Self.postStartByRepoKey)
    }

    /// The post-start script a new worktree of `path` runs — the repo override
    /// when set, otherwise the global default. The per-worktree field seeds
    /// from this.
    func postStartScript(forRepo path: String) -> String {
        postStartScriptByRepo[path] ?? postStartScriptGlobal
    }

    /// The repo's explicit agent override, or nil when it inherits the global.
    func repoAgentOverride(forRepo path: String) -> Agent? {
        agentByRepo[path].flatMap(Agent.init(rawValue:))
    }

    /// Sets the repo's agent override, or clears it (nil) to inherit the global.
    func setRepoAgentOverride(_ agent: Agent?, forRepo path: String) {
        if let agent {
            agentByRepo[path] = agent.rawValue
        } else {
            agentByRepo.removeValue(forKey: path)
        }
        UserDefaults.standard.set(agentByRepo, forKey: Self.agentByRepoKey)
    }

    /// The agent a new worktree of `path` uses — repo override, else global.
    func agent(forRepo path: String) -> Agent {
        repoAgentOverride(forRepo: path) ?? defaultAgent
    }

    /// The agent that was pinned to a specific worktree at creation, if any.
    func worktreeAgentOverride(forWorktree path: String) -> Agent? {
        agentByWorktree[path].flatMap(Agent.init(rawValue:))
    }

    /// Pins a worktree to the agent it was created with.
    func setWorktreeAgent(_ agent: Agent, forWorktree path: String) {
        agentByWorktree[path] = agent.rawValue
        UserDefaults.standard.set(agentByWorktree, forKey: Self.agentByWorktreeKey)
    }

    /// The agent operating in an existing worktree, resolved in priority order:
    /// the agent it was created with, then the agent of its most recent session
    /// (so worktrees Spark Plug didn't create still resolve correctly), then the
    /// repo override, then the global default.
    func agent(for worktree: Worktree) -> Agent {
        if let pinned = worktreeAgentOverride(forWorktree: worktree.url.path) { return pinned }
        if let latest = worktree.sessions.first?.agent { return latest }
        return worktree.projectPath.map { agent(forRepo: $0) } ?? defaultAgent
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
                        sessions: AgentSessions.all(for: dir)
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
        sessionName: String? = nil,
        sessionChoice: SessionChoice = .automatic,
        openClaude: Bool = true,
        postStartScript: String = "",
        agent: Agent = .claude
    ) {
        let repo = (sourceRepo as NSString).expandingTildeInPath
        let base = localBase(baseBranch, in: repo)
        let dirName = worktreeFolderName(repo: repo, ticket: ticket, brief: briefName)
        let rootExpanded = (rootPath as NSString).expandingTildeInPath
        let worktreePath = (rootExpanded as NSString).appendingPathComponent(dirName)
        // Pin this worktree to its agent so later "New session" / resume default
        // to it, even when it differs from the repo/global default.
        setWorktreeAgent(agent, forWorktree: worktreePath)
        let useScript = willUseSetupScript(repo: repo, ticket: ticket)
        let setupCmd: String
        if useScript {
            setupCmd = setupCommandTemplate
                .replacingOccurrences(of: "{ticket}", with: singleQuote(ticket))
                .replacingOccurrences(of: "{brief}", with: singleQuote(briefName))
                .replacingOccurrences(of: "{base}", with: singleQuote(base))
        } else {
            setupCmd = "git worktree add -b \(singleQuote(dirName)) "
                + "\(singleQuote(worktreePath)) \(singleQuote(base))"
        }
        // Provision from the worktree that has the base branch checked out, not
        // the source repo: the setup script and the tools it invokes must come
        // from the same commit the new worktree is branched from. Falls back to
        // the source repo when the base isn't checked out anywhere.
        let scriptDir = useScript
            ? provisioningDir(sourceRepo: repo, baseBranch: base)
            : repo
        // The worktree folder names the multiplexer's window/workspace, so a
        // running session is identifiable from the folder it lives in. The
        // Claude session takes just the descriptive name the user typed (the
        // "final part"), never the ticket or project prefix the folder carries.
        let trimmedSession = (sessionName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let sessionLabel = trimmedSession.isEmpty ? briefName : trimmedSession
        // With the agent off, provision the worktree and drop the user at a
        // ready shell in it; otherwise launch the agent as the final step.
        var command = "cd \(singleQuote(scriptDir)) && \(setupCmd) "
            + "&& cd \(singleQuote(worktreePath)) && clear"
        // Post-start script runs *inside* the new worktree, after provisioning
        // and before the agent takes over the terminal. {ticket} {brief} {base}
        // are substituted verbatim (unquoted) — unlike the setup command's args
        // — so they can sit inside the user's own quoting, e.g.
        // `claude -n "{ticket}-{brief}"` to name a session with no setup script.
        // Empty means run nothing.
        let postStart = postStartScript
            .replacingOccurrences(of: "{ticket}", with: ticket)
            .replacingOccurrences(of: "{brief}", with: briefName)
            .replacingOccurrences(of: "{base}", with: base)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !postStart.isEmpty {
            // Group the user's script in a subshell so a trailing control
            // operator stays valid once the agent chain is appended. Bare
            // concatenation of e.g. `bun dev &` yields `... && bun dev & && claude`,
            // a syntax error — and since the whole line is parsed before it runs,
            // that aborts everything, provisioning included. `... && (bun dev &) && claude`
            // parses cleanly and detaches the background job as intended. A
            // subshell needs no trailing terminator, so `(foo)`, `(foo &)` and
            // `(foo;)` are all valid.
            command += " && (\(postStart))"
        }
        if openClaude {
            command += " && \(agent.newSessionCommand(name: sessionLabel))"
        }
        // Bring the base branch up to date with its remote *before* cutting the
        // worktree, off the main actor so the network I/O never freezes the UI.
        // A clean refresh is silent; a stash reapply that conflicts surfaces via
        // `errorMessage` (the launched terminal can't report back — `clear` and
        // Claude take the screen). Either way the worktree is still created.
        Task {
            if let warning = await Task.detached(priority: .userInitiated, operation: {
                Self.refreshBase(repo: repo, base: base)
            }).value {
                self.errorMessage = warning
            }
            self.launch(command, windowName: dirName, choice: sessionChoice)
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
        // `stash push` exits 0 both when it stashes and when there is nothing
        // to stash ("No local changes to save"), so the exit code can't tell
        // us whether a stash was created. Compare refs/stash instead: pop only
        // a stash this refresh actually pushed — never a pre-existing entry
        // the user is deliberately keeping.
        let stashBefore = git(["rev-parse", "--verify", "--quiet", "refs/stash"]).output
        git(["stash", "push", "-u", "-m", "spark-plug-autostash"])
        let didStash = git(["rev-parse", "--verify", "--quiet", "refs/stash"]).output != stashBefore
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
        baseBranch: String? = nil,
        openClaude: Bool = true,
        postStartScript: String = "",
        agent: Agent = .claude
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
            baseBranch: baseBranch ?? defaultBaseBranch(in: repoPath),
            sessionName: name.trimmingCharacters(in: .whitespacesAndNewlines),
            openClaude: openClaude,
            postStartScript: postStartScript,
            agent: agent
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

    /// Configured remote names (e.g. "origin"); empty when there are none or
    /// `repoPath` isn't a git repo.
    func remotes(in repoPath: String) -> [String] {
        let res = runGit(["-C", repoPath, "remote"])
        guard res.status == 0, !res.output.isEmpty else { return [] }
        return res.output.components(separatedBy: "\n").filter { !$0.isEmpty }
    }

    /// The local branch a base selection maps to: a remote-tracking ref such as
    /// "origin/develop" is reduced to "develop" when a matching local branch
    /// exists, so branching from the remote behaves identically to branching
    /// from the local branch — same worktree name, same setup-script naming.
    /// Local names (including slashed ones like "feature/foo") and remote refs
    /// with no local counterpart are returned unchanged so they still branch.
    func localBase(_ base: String, in repoPath: String) -> String {
        for remote in remotes(in: repoPath) where base.hasPrefix("\(remote)/") {
            let local = String(base.dropFirst(remote.count + 1))
            return localBranchExists(in: repoPath, branch: local) ? local : base
        }
        return base
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

    /// Resumes a past session in the agent that created it. Surfaces a message
    /// for agents whose resume isn't wired up yet rather than launching wrongly.
    func resumeSession(_ session: AgentSession, in worktree: Worktree) {
        guard let resume = session.agent.resumeCommand(sessionId: session.id) else {
            errorMessage = "\(session.agent.displayName) can't be resumed from Spark Plug yet."
            return
        }
        let command = "cd \(singleQuote(worktree.url.path)) && clear && \(resume)"
        launch(command, windowName: windowName(worktree: worktree.name, session: session.title))
    }

    /// Starts a fresh session of `agent` in a worktree. The typed name labels
    /// the session where the agent supports naming (Claude today) and always
    /// labels the multiplexer window/workspace.
    func startSession(in worktree: Worktree, agent: Agent, name: String?) {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let command = "cd \(singleQuote(worktree.url.path)) && clear && "
            + agent.newSessionCommand(name: trimmed)
        launch(command, windowName: windowName(worktree: worktree.name, session: trimmed))
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

    // MARK: - Launching

    /// Launches `command` in the selected multiplexer: reuses the only running
    /// session, starts one if none exist, or asks the user to pick when several
    /// are running. Falls back to a plain Terminal window when the multiplexer
    /// isn't installed.
    private func launch(_ command: String, windowName: String, choice: SessionChoice = .automatic) {
        guard multiplexerAvailable else {
            runInTerminal(command)
            return
        }
        switch choice {
        case .session(let name):
            openInSession(command, windowName: windowName, session: name)
        case .newSession:
            openInSession(command, windowName: windowName, session: nil)
        case .automatic:
            let sessions = runningSessionNames()
            if sessions.count > 1 {
                pendingSessionLaunch = PendingSessionLaunch(
                    command: command, windowName: windowName, sessionNames: sessions)
            } else {
                openInSession(command, windowName: windowName, session: sessions.first)
            }
        }
    }

    /// Resolves a pending launch with the chosen session (nil = new session).
    func completePendingLaunch(session: String?) {
        guard let pending = pendingSessionLaunch else { return }
        pendingSessionLaunch = nil
        openInSession(pending.command, windowName: pending.windowName, session: session)
    }

    /// Whether the selected multiplexer's binary is installed.
    private var multiplexerAvailable: Bool {
        switch multiplexer {
        case .tmux: return tmuxPath != nil
        case .herdr: return herdrPath != nil
        }
    }

    /// Names of running sessions for the selected multiplexer — drives the
    /// automatic reuse/ask logic and the session picker.
    func runningSessionNames() -> [String] {
        switch multiplexer {
        case .tmux: return tmuxSessionNames()
        case .herdr: return herdrRunningSessionNames()
        }
    }

    /// Opens `command` in `session` (nil = start a new session) using the
    /// selected multiplexer.
    private func openInSession(_ command: String, windowName: String, session: String?) {
        switch multiplexer {
        case .tmux: launchInTmux(command, windowName: windowName, session: session)
        case .herdr: launchInHerdr(command, windowName: windowName, session: session)
        }
    }

    // MARK: - tmux

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

    // MARK: - Herdr

    private var herdrPath: String? {
        [("~/.local/bin/herdr" as NSString).expandingTildeInPath,
         "/opt/homebrew/bin/herdr", "/usr/local/bin/herdr",
         "/opt/local/bin/herdr", "/usr/bin/herdr"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Names of *running* Herdr sessions ([] when none, or herdr is missing).
    func herdrRunningSessionNames() -> [String] {
        herdrSessions().filter { $0.running }.map { $0.name }
    }

    /// Parses the columnar `herdr session list` output — `name status directory
    /// socket`, one row per session after a header — into (name, running) pairs.
    /// Only the first two columns are read, so directory paths with spaces are
    /// harmless.
    private func herdrSessions() -> [(name: String, running: Bool)] {
        guard let herdr = herdrPath else { return [] }
        let res = runProcess(herdr, ["session", "list"])
        guard res.status == 0 else { return [] }
        return res.output.components(separatedBy: "\n").compactMap { line in
            let cols = line.split(whereSeparator: \.isWhitespace)
            guard cols.count >= 2, cols[0] != "name" else { return nil }  // skip header
            return (String(cols[0]), cols[1] == "running")
        }
    }

    /// Directories that currently have a live agent, across every running Herdr
    /// session. Herdr's `agents` array lists only detected, running agents, so
    /// this is authoritative for *all* agent kinds — the runtime liveness signal
    /// the session stores can't provide. Collects each agent's cwd/foreground
    /// cwd and its workspace's worktree checkout path (over-inclusive on purpose,
    /// so a destructive guard errs toward blocking). Called on demand, never in
    /// `scan()`.
    func herdrLiveAgentDirs() -> Set<String> {
        guard let herdr = herdrPath else { return [] }
        var dirs = Set<String>()
        for session in herdrRunningSessionNames() {
            let res = runProcess(herdr, ["--session", session, "api", "snapshot"])
            guard res.status == 0, let data = res.output.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let result = obj["result"] as? [String: Any],
                  let snapshot = result["snapshot"] as? [String: Any],
                  let agents = snapshot["agents"] as? [[String: Any]] else { continue }
            var checkoutByWorkspace: [String: String] = [:]
            if let workspaces = snapshot["workspaces"] as? [[String: Any]] {
                for ws in workspaces {
                    if let id = ws["workspace_id"] as? String,
                       let worktree = ws["worktree"] as? [String: Any],
                       let path = worktree["checkout_path"] as? String {
                        checkoutByWorkspace[id] = path
                    }
                }
            }
            for agent in agents {
                if let d = agent["foreground_cwd"] as? String { dirs.insert(d) }
                if let d = agent["cwd"] as? String { dirs.insert(d) }
                if let id = agent["workspace_id"] as? String,
                   let p = checkoutByWorkspace[id] { dirs.insert(p) }
            }
        }
        return dirs
    }

    /// Whether an agent is currently running in `wt`, per the multiplexer's live
    /// view — or nil when the multiplexer can't report it (tmux has no agent
    /// state), leaving the caller to fall back to conservative session-based
    /// guards. A directory matches when it is the worktree or a path inside it.
    func worktreeHasLiveAgent(_ wt: Worktree) -> Bool? {
        switch multiplexer {
        case .tmux:
            return nil
        case .herdr:
            let path = wt.url.path
            return herdrLiveAgentDirs().contains { $0 == path || $0.hasPrefix(path + "/") }
        }
    }

    /// Opens a Herdr workspace for `command`. With a running `session` the
    /// workspace is created straight away; with nil (no session running, or the
    /// user asked for a new one) a Herdr client is launched in a terminal first
    /// — Herdr can't create a session headlessly — then the workspace is opened
    /// once its socket comes up. Mirrors the tmux launch flow.
    private func launchInHerdr(_ command: String, windowName: String, session: String?) {
        guard herdrPath != nil else {
            runInTerminal(command)
            return
        }
        if let session {
            openHerdrWorkspace(command, windowName: windowName, session: session)
        } else {
            startHerdrSessionThenOpen(command, windowName: windowName)
        }
    }

    /// Creates a workspace in `session`, then types `command` into its pane's
    /// login shell and submits it — typing rather than passing the command
    /// directly so the user's PATH (claude, nvm, etc.) is in effect, exactly as
    /// the tmux path does. The workspace label mirrors the tmux window name.
    private func openHerdrWorkspace(_ command: String, windowName: String, session: String) {
        guard let herdr = herdrPath else {
            runInTerminal(command)
            return
        }
        let label = windowName.isEmpty ? "claude" : windowName
        // `--focus` lands the user on the new workspace in Herdr, rather than
        // leaving it to surface unnoticed behind the one they were viewing.
        let created = runProcess(herdr, ["--session", session, "workspace", "create",
                                         "--label", label, "--focus"])
        guard created.status == 0,
              let paneId = Self.herdrPaneId(fromCreateJSON: created.output) else {
            errorMessage = "Herdr couldn't open a workspace: \(created.output)"
            return
        }
        runProcess(herdr, ["--session", session, "pane", "send-text", paneId, command])
        runProcess(herdr, ["--session", session, "pane", "send-keys", paneId, "Enter"])
    }

    /// Starts Herdr's `default` session (via a terminal, which both creates it
    /// and attaches a viewer), waits off the main actor for its socket to come
    /// up, then opens the workspace. If `default` is already running the wait is
    /// skipped. Surfaces a warning if the session never comes up — the worktree
    /// is created either way and can be opened in Herdr by hand.
    private func startHerdrSessionThenOpen(_ command: String, windowName: String) {
        let target = "default"
        if herdrRunningSessionNames().contains(target) {
            openHerdrWorkspace(command, windowName: windowName, session: target)
            return
        }
        guard let herdr = herdrPath else {
            runInTerminal(command)
            return
        }
        runInTerminal(herdr)  // `herdr` with no --session launches the default session
        Task {
            let ready = await Task.detached(priority: .userInitiated) {
                Self.waitForHerdrSession(herdr: herdr, name: target, attempts: 60)
            }.value
            if ready {
                self.openHerdrWorkspace(command, windowName: windowName, session: target)
            } else {
                self.errorMessage = "Herdr didn't start in time — the worktree is "
                    + "ready; open it in Herdr manually."
            }
        }
    }

    /// Polls `herdr session list` up to `attempts` times (0.25s apart) until
    /// `name` reports `running`. Runs off the main actor.
    nonisolated private static func waitForHerdrSession(
        herdr: String, name: String, attempts: Int
    ) -> Bool {
        for _ in 0..<attempts {
            let res = runProcessSync(herdr, ["session", "list"])
            if res.status == 0 {
                for line in res.output.components(separatedBy: "\n") {
                    let cols = line.split(whereSeparator: \.isWhitespace)
                    if cols.count >= 2, cols[0] == name, cols[1] == "running" { return true }
                }
            }
            Thread.sleep(forTimeInterval: 0.25)
        }
        return false
    }

    /// Extracts `result.root_pane.pane_id` from `herdr workspace create`'s JSON.
    nonisolated private static func herdrPaneId(fromCreateJSON json: String) -> String? {
        guard let start = json.firstIndex(of: "{") else { return nil }
        let data = Data(json[start...].utf8)
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = obj["result"] as? [String: Any],
              let rootPane = result["root_pane"] as? [String: Any],
              let paneId = rootPane["pane_id"] as? String else { return nil }
        return paneId
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

    func revealSessionInFinder(_ session: AgentSession) {
        guard let url = session.fileURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// Permanently deletes a session's transcript via its agent's provider.
    /// Refuses to act on a live session, and reports when an agent's store
    /// doesn't support deletion here.
    @discardableResult
    func deleteSession(_ session: AgentSession) -> Bool {
        guard !session.blocksDestruction else {
            errorMessage = "Cannot delete — quit \(session.agent.displayName) first "
                + "(or Spark Plug can't confirm this session isn't running)."
            return false
        }
        guard session.agent.sessionProvider.deleteSession(session) else {
            errorMessage = "Couldn't delete this \(session.agent.displayName) session."
            return false
        }
        scan()
        return true
    }

    /// Permanently removes a worktree. For a real git worktree this runs
    /// `git worktree remove --force` (so the main repo's metadata is cleaned
    /// up too); for a plain folder it deletes the directory. Refuses when a
    /// session is live, or when liveness can't be verified (e.g. OpenCode), so
    /// `--force` never discards work an agent may still be using. Claude
    /// transcripts under ~/.claude are left intact — delete those separately.
    @discardableResult
    func deleteWorktree(_ wt: Worktree) -> Bool {
        Self.debugLog("deleteWorktree: \(wt.url.path)")
        // Never force-remove a worktree an agent may still be using. Prefer the
        // multiplexer's live view (authoritative for every agent kind); when it
        // can't report (tmux), fall back to session state — treating a session
        // whose liveness is unverifiable (e.g. OpenCode) as possibly-live.
        let sessions = AgentSessions.all(for: wt.url)
        let sessionsBlock = sessions.contains { $0.blocksDestruction }
        if sessions.contains(where: { $0.isLive }) || (worktreeHasLiveAgent(wt) ?? sessionsBlock) {
            Self.debugLog("deleteWorktree blocked: live/unverifiable agent in \(wt.name)")
            errorMessage = "Cannot delete — an agent may be running here. Quit any sessions "
                + "in this worktree first. If Spark Plug can't verify an agent's state and "
                + "isn't managing it in Herdr, close it and retry, or remove the worktree from the terminal."
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
        } catch {
            debugLog("\(path) \(args.joined(separator: " ")) → spawn failed: \(error.localizedDescription)")
            return (-1, error.localizedDescription)
        }
        // Drain the (merged stdout+stderr) pipe to EOF before waiting, so large
        // output can't fill the pipe buffer and deadlock the process.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
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
