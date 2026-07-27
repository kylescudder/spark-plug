import SwiftUI

private let relativeFormatter: RelativeDateTimeFormatter = {
    let f = RelativeDateTimeFormatter()
    f.unitsStyle = .abbreviated
    return f
}()

/// Tight "3m" / "2h" / "5d" / "2w" / "4mo" / "1y" style — no "ago".
private func relativeShort(_ date: Date) -> String {
    let secs = max(0, Date().timeIntervalSince(date))
    switch secs {
    case ..<60:       return "just now"
    case ..<3600:     return "\(Int(secs / 60))m"
    case ..<86_400:   return "\(Int(secs / 3600))h"
    case ..<604_800:  return "\(Int(secs / 86_400))d"
    case ..<2_592_000:return "\(Int(secs / 604_800))w"
    case ..<31_536_000: return "\(Int(secs / 2_592_000))mo"
    default:          return "\(Int(secs / 31_536_000))y"
    }
}

struct ContentView: View {
    @ObservedObject private var store = WorktreeStore.shared
    private static let collapsedKey = "SparkPlug.collapsedProjects"
    @State private var collapsedProjects: Set<String> =
        Set(UserDefaults.standard.stringArray(forKey: collapsedKey) ?? [])
    @State private var pendingNewSession: Worktree?
    @State private var pendingNewWorktree: ProjectGroup?
    @State private var sessionToDelete: AgentSession?
    @State private var worktreeToDelete: Worktree?
    @Environment(\.openWindow) private var openWindow
    /// Tracks the focus state of the hosting window. The menu-bar popover is an
    /// NSPanel that becomes `.key` when opened and `.inactive` when dismissed —
    /// so this flipping to `.key` is our "the menu was just opened" signal.
    @Environment(\.controlActiveState) private var controlActiveState

    var body: some View {
        // Modals are rendered as in-view overlays, NOT .sheet/.confirmationDialog:
        // buttons inside presented containers in a MenuBarExtra window render
        // but never fire their actions (macOS bug). Inline views work.
        ZStack {
            VStack(spacing: 0) {
                header
                Divider()
                if let msg = store.errorMessage {
                    Text(msg)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal)
                        .padding(.vertical, 6)
                }
                list
                Divider()
                footer
            }
            modalOverlay
        }
        .onChange(of: controlActiveState) { _, state in
            // Auto-refresh whenever the window/popover regains focus — opening
            // the menu-bar item re-scans without the user hitting Rescan.
            if state == .key { store.scan() }
        }
    }

    @ViewBuilder
    private var modalOverlay: some View {
        if isModalActive {
            Color.black.opacity(0.35)
                .onTapGesture { }  // swallow clicks behind the modal
            Group {
                if let wt = pendingNewSession {
                    NewSessionCard(
                        worktree: wt,
                        agent: store.agent(for: wt),
                        windowNoun: store.multiplexer.windowNoun,
                        onCancel: { pendingNewSession = nil }
                    ) { name in
                        store.startSession(in: wt, agent: store.agent(for: wt), name: name)
                        store.scan()
                        pendingNewSession = nil
                    }
                } else if let group = pendingNewWorktree {
                    NewWorktreeCard(
                        group: group,
                        store: store,
                        onCancel: { pendingNewWorktree = nil },
                        onDone: {
                            store.scan()
                            pendingNewWorktree = nil
                        }
                    )
                } else if let session = sessionToDelete {
                    let title = session.title
                        ?? session.firstMessage.map { $0.count > 40 ? String($0.prefix(40)) + "…" : $0 }
                        ?? String(session.id.prefix(8))
                    ConfirmDeleteCard(
                        title: "Delete this session?",
                        message: "This permanently deletes the transcript for “\(title)”. This can't be undone.",
                        confirmLabel: "Delete",
                        onConfirm: { store.deleteSession(session) },
                        onDismiss: { sessionToDelete = nil }
                    )
                } else if let wt = worktreeToDelete {
                    ConfirmDeleteCard(
                        title: "Delete this worktree?",
                        message: "This permanently deletes the folder “\(wt.name)” and everything in it. If it's a git worktree, any uncommitted changes are lost and its “\(wt.name)” branch is deleted too. This can't be undone.",
                        confirmLabel: "Delete Worktree",
                        onConfirm: { store.deleteWorktree(wt) },
                        onDismiss: { worktreeToDelete = nil }
                    )
                } else if let launch = store.pendingSessionLaunch {
                    SessionPickerCard(launch: launch, store: store)
                }
            }
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            .shadow(radius: 24)
            .padding(24)
        }
    }

    private var isModalActive: Bool {
        pendingNewSession != nil || pendingNewWorktree != nil
            || sessionToDelete != nil || worktreeToDelete != nil
            || store.pendingSessionLaunch != nil
    }

    private var footer: some View {
        HStack {
            Text("\(store.worktrees.count) worktrees · \(store.projectGroups.count) projects")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button {
                NSApp.terminate(nil)
            } label: {
                Label("Quit", systemImage: "power")
            }
            .buttonStyle(.borderless)
            .keyboardShortcut("q", modifiers: .command)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "bolt.fill")
                .font(.title2)
                .foregroundStyle(.yellow)
            VStack(alignment: .leading, spacing: 2) {
                Text("Spark Plug").font(.headline)
                Text(store.rootPath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Button {
                store.addRepo()
            } label: {
                Label("Add Repo", systemImage: "plus.square.on.square")
            }
            .keyboardShortcut("n", modifiers: .command)
            .help("Register a base repository — new worktrees are created from its project header")
            Button {
                store.pickFolder()
            } label: {
                Label("Folder", systemImage: "folder")
            }
            Button {
                store.scan()
            } label: {
                Label("Rescan", systemImage: "arrow.clockwise")
            }
            .keyboardShortcut("r", modifiers: .command)
            Button {
                openWindow(id: "settings")
                // Accessory apps don't come forward on openWindow alone.
                NSApp.activate(ignoringOtherApps: true)
            } label: {
                Label("Settings", systemImage: "gearshape")
            }
            .keyboardShortcut(",", modifiers: .command)
            .help("View app version and edit settings")
        }
        .padding(12)
    }

    private var list: some View {
        Group {
            if store.worktrees.isEmpty && store.registeredRepos.isEmpty {
                ContentUnavailableView(
                    "No projects",
                    systemImage: "tray",
                    description: Text("Add a base repo to start creating worktrees.")
                )
            } else {
                // A plain VStack instead of List: NSTableView-backed Lists
                // snap rather than animate conditional section content.
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(store.projectGroups) { group in
                            projectHeader(group)
                            if !collapsedProjects.contains(group.id) {
                                groupRows(group)
                            }
                        }
                    }
                    .animation(.easeInOut(duration: 0.2), value: collapsedProjects)
                    .padding(.vertical, 4)
                }
            }
        }
    }

    @ViewBuilder
    private func groupRows(_ group: ProjectGroup) -> some View {
        Group {
            if group.worktrees.isEmpty {
                Text("No worktrees yet")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 32)
                    .padding(.vertical, 8)
            } else {
                ForEach(group.worktrees) { wt in
                    row(for: wt)
                        .padding(.horizontal, 12)
                    if wt.id != group.worktrees.last?.id {
                        Divider().padding(.leading, 40)
                    }
                }
            }
        }
        .transition(.opacity)
    }

    private func toggleCollapsed(_ id: String) {
        if collapsedProjects.contains(id) {
            collapsedProjects.remove(id)
        } else {
            collapsedProjects.insert(id)
        }
        UserDefaults.standard.set(Array(collapsedProjects), forKey: Self.collapsedKey)
    }

    @ViewBuilder
    private func projectHeader(_ group: ProjectGroup) -> some View {
        let isOther = group.path == nil
        HStack(spacing: 6) {
            // Collapse toggle is its own button so the trailing actions stay
            // independently clickable.
            Button {
                toggleCollapsed(group.id)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(collapsedProjects.contains(group.id) ? 0 : 90))
                    Image(systemName: isOther ? "folder" : "shippingbox.fill")
                        .foregroundStyle(isOther
                                         ? AnyShapeStyle(.secondary) : AnyShapeStyle(.yellow))
                    Text(group.name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text("\(group.worktrees.count)")
                        .font(.caption2)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.secondary.opacity(0.15), in: Capsule())
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(group.path ?? group.name)

            if let path = group.path {
                Button {
                    pendingNewWorktree = group
                } label: {
                    Label("Worktree", systemImage: "plus")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Create a new \(group.name) worktree")

                Menu {
                    Menu("Agent") {
                        Picker("Agent", selection: Binding<Agent?>(
                            get: { store.repoAgentOverride(forRepo: path) },
                            set: { store.setRepoAgentOverride($0, forRepo: path) })) {
                            Text("Inherit (\(store.defaultAgent.displayName))").tag(Agent?.none)
                            ForEach(Agent.allCases) { a in
                                Text(a.displayName).tag(Agent?.some(a))
                            }
                        }
                    }
                    Picker("Launch agent on start", selection: Binding<Bool?>(
                        get: { store.repoOpenClaudeOverride(forRepo: path) },
                        set: { store.setRepoOpenClaudeOverride($0, forRepo: path) })) {
                        Text("Inherit (Global: \(store.openClaudeOnStartGlobal ? "On" : "Off"))")
                            .tag(Bool?.none)
                        Text("On").tag(Bool?.some(true))
                        Text("Off").tag(Bool?.some(false))
                    }
                    // Forgetting a repo only makes sense once it has no worktrees
                    // left to keep rediscovering it.
                    if group.isRegistered && group.worktrees.isEmpty {
                        Divider()
                        Button {
                            store.removeRepo(path)
                        } label: {
                            Label("Remove from list", systemImage: "minus.circle")
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("\(group.name) settings")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(Color.secondary.opacity(0.07))
    }

    @ViewBuilder
    private func row(for wt: Worktree) -> some View {
        HStack(spacing: 10) {
            Image(systemName: wt.isGitRepo ? "point.3.connected.trianglepath.dotted" : "folder")
                .foregroundStyle(wt.isGitRepo ? .green : .secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(wt.name).font(.body)
                HStack(spacing: 6) {
                    Text(wt.url.path)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if wt.hasSessions {
                        sessionBadge(wt)
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                store.openInFinder(wt)
            } label: {
                Image(systemName: "folder")
            }
            .help("Open in Finder")
            .buttonStyle(.borderless)

            continueMenu(for: wt)

            Button {
                pendingNewSession = wt
            } label: {
                Label("New", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .help("Start a new Claude session")

            Menu {
                Button(role: .destructive) {
                    worktreeToDelete = wt
                } label: {
                    Label("Delete Worktree…", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More actions")
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func continueMenu(for wt: Worktree) -> some View {
        let sessions = wt.sessions
        // Show the agent name alongside each session only when the worktree
        // has history from more than one agent.
        let multiAgent = Set(sessions.map(\.agent)).count > 1
        Menu {
            if sessions.isEmpty {
                Text("No sessions yet")
            } else {
                ForEach(sessions) { s in
                    Menu {
                        Button {
                            store.resumeSession(s, in: wt)
                        } label: {
                            Label("Resume", systemImage: "arrow.uturn.forward")
                        }
                        .disabled(s.isLive || !s.agent.supportsResume)

                        if s.canReveal {
                            Button {
                                store.revealSessionInFinder(s)
                            } label: {
                                Label("Show Transcript in Finder", systemImage: "doc.text.magnifyingglass")
                            }
                        }

                        if s.canDelete {
                            Divider()
                            Button(role: .destructive) {
                                sessionToDelete = s
                            } label: {
                                Label("Delete…", systemImage: "trash")
                            }
                            .disabled(s.isLive)
                        }
                    } label: {
                        Text(multiAgent ? "\(s.agent.displayName) · \(sessionLabel(s))" : sessionLabel(s))
                    }
                }
            }
        } label: {
            Label("Continue", systemImage: "arrow.uturn.forward")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(sessions.isEmpty)
        .help(sessions.isEmpty ? "No prior sessions" : "Resume an existing session")
    }

    private func sessionTitle(_ s: AgentSession) -> String {
        if let t = s.title, !t.isEmpty { return t }
        if let first = s.firstMessage, !first.isEmpty {
            return first.count > 60 ? String(first.prefix(60)) + "…" : first
        }
        return String(s.id.prefix(8))
    }

    private func sessionLabel(_ s: AgentSession) -> String {
        let when = relativeShort(s.lastModified)
        let live = s.isLive ? "● live · " : ""
        return "\(live)\(sessionTitle(s)) · \(when)"
    }

    @ViewBuilder
    private func sessionBadge(_ wt: Worktree) -> some View {
        let label: String = {
            if let last = wt.lastSessionAt {
                return "\(wt.sessionCount) · \(relativeShort(last))"
            }
            return "\(wt.sessionCount)"
        }()
        HStack(spacing: 3) {
            Image(systemName: "sparkle")
            Text(label)
        }
        .font(.caption2)
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Color.orange.opacity(0.18), in: Capsule())
        .foregroundStyle(.orange)
        .help("\(wt.sessionCount) agent session\(wt.sessionCount == 1 ? "" : "s") for this folder")
    }
}

/// In-popover replacement for a destructive confirmationDialog. `onConfirm`
/// returns whether the action succeeded; on failure the card stays open and
/// shows the store's error so it can't vanish with the popover.
private struct ConfirmDeleteCard: View {
    let title: String
    let message: String
    let confirmLabel: String
    let onConfirm: () -> Bool
    let onDismiss: () -> Void

    @State private var failureMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
                Text(title).font(.headline)
            }
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let failureMessage {
                Label(failureMessage, systemImage: "xmark.octagon.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel") { onDismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(confirmLabel, role: .destructive) {
                    if onConfirm() {
                        onDismiss()
                    } else {
                        failureMessage = WorktreeStore.shared.errorMessage
                            ?? "Delete failed for an unknown reason."
                    }
                }
            }
        }
        .padding(20)
        .frame(width: 400)
    }
}

/// In-popover session chooser, shown when several of the selected
/// multiplexer's sessions are running at launch time.
private struct SessionPickerCard: View {
    let launch: PendingSessionLaunch
    @ObservedObject var store: WorktreeStore

    private var name: String { store.multiplexer.displayName }
    private var noun: String { store.multiplexer.windowNoun }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "terminal")
                    .foregroundStyle(.yellow)
                Text("Which \(name) session?").font(.headline)
            }
            Text("Multiple \(name) sessions are running. Choose where to open the new Claude \(noun).")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 6) {
                ForEach(launch.sessionNames, id: \.self) { session in
                    Button {
                        store.completePendingLaunch(session: session)
                    } label: {
                        Text(session).frame(maxWidth: .infinity)
                    }
                }
                Button {
                    store.completePendingLaunch(session: nil)
                } label: {
                    Text("New \(name) Session").frame(maxWidth: .infinity)
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { store.pendingSessionLaunch = nil }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 400)
    }
}

private struct NewSessionCard: View {
    let worktree: Worktree
    /// The agent this session will start (drives the title).
    let agent: Agent
    /// What the selected multiplexer calls its container ("window"/"workspace").
    let windowNoun: String
    let onCancel: () -> Void
    let onStart: (String) -> Void

    @State private var name: String = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "sparkle")
                    .foregroundStyle(.yellow)
                Text("New \(agent.displayName) session").font(.headline)
            }
            Text(worktree.url.path)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            TextField("Session name (e.g. \"refactor auth flow\")", text: $name)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit(commit)

            Text(preview)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            HStack {
                Spacer()
                Button("Cancel") { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Button("Start") { commit() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(trimmed.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear { focused = true }
    }

    private var trimmed: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var preview: String {
        guard !trimmed.isEmpty else {
            return "Starts a Claude session in this worktree."
        }
        return "\(windowNoun.capitalized): “\(worktree.name) — \(trimmed)”"
    }

    private func commit() {
        guard !trimmed.isEmpty else { return }
        onStart(trimmed)
    }
}

/// Per-project worktree creation: a name plus optional ticket — the repo
/// comes from the group, the fork point defaults to the branch checked out in
/// the base repo (with a dropdown to branch off any local or remote branch
/// instead). The folder/branch and the multiplexer's window/workspace take the
/// `ticket_brief` name; the Claude session takes just the descriptive name.
private struct NewWorktreeCard: View {
    let group: ProjectGroup
    @ObservedObject var store: WorktreeStore
    let onCancel: () -> Void
    let onDone: () -> Void

    @State private var name: String = ""
    @State private var ticket: String = ""
    @State private var problem: String?
    /// Every local and remote branch of the base repo (the fork-point choices).
    @State private var branches: [String] = []
    @State private var selectedBranch: String?
    /// The branch checked out in the base repo — the default fork point, tagged
    /// "(current)" in the picker.
    @State private var currentBranch: String?
    /// Agent + launch-on-start for this worktree, both seeded from the repo's
    /// resolved defaults in `onAppear`, then overridable here for this one.
    @State private var agent: Agent = .claude
    @State private var openClaude: Bool = true
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "plus.rectangle.on.folder")
                    .foregroundStyle(.yellow)
                Text("New \(group.name) worktree").font(.headline)
            }
            if let path = group.path {
                Text(path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Ticket (optional)").font(.caption).foregroundStyle(.secondary)
                    TextField("MP5-12345", text: $ticket)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 110)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Name").font(.caption).foregroundStyle(.secondary)
                    TextField("Fix auth timeout", text: $name)
                        .textFieldStyle(.roundedBorder)
                        .focused($focused)
                        .onSubmit(commit)
                }
            }

            // Only worth a picker once there's more than one branch to choose
            // between; a lone branch is just used silently as the fork point.
            if branches.count > 1 {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Branch from").font(.caption).foregroundStyle(.secondary)
                    Picker("Branch from", selection: $selectedBranch) {
                        ForEach(branches, id: \.self) { branch in
                            Text(branch == currentBranch ? "\(branch) (current)" : branch)
                                .tag(branch as String?)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Agent").font(.caption).foregroundStyle(.secondary)
                Picker("Agent", selection: $agent) {
                    ForEach(Agent.allCases) { a in Text(a.displayName).tag(a) }
                }
                .labelsHidden()
                .pickerStyle(.menu)
            }

            Toggle("Launch \(agent.displayName) on start", isOn: $openClaude)
                .toggleStyle(.checkbox)
                .font(.caption)

            Text(preview)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            if let problem {
                Label(problem, systemImage: "exclamationmark.triangle")
                    .font(.caption2)
                    .foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("Cancel") { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Button("Create") { commit() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(trimmed.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 440)
        .onAppear {
            focused = true
            buildBranches()
            openClaude = group.path.map { store.openClaudeOnStart(forRepo: $0) } ?? true
            agent = group.path.map { store.agent(forRepo: $0) } ?? store.defaultAgent
        }
        .onChange(of: name) { problem = nil }
        .onChange(of: ticket) { problem = nil }
    }

    private var trimmed: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Every local and remote branch of the base repo, defaulting the selection
    /// to the branch it currently has checked out (falling back to the
    /// conventional default, then the first branch listed).
    private func buildBranches() {
        guard let path = group.path else { return }
        branches = store.branches(in: path)
        let current = store.currentBranch(in: path)
        currentBranch = current
        selectedBranch = current.flatMap { branches.contains($0) ? $0 : nil }
            ?? branches.first { $0 == store.defaultBaseBranch(in: path) }
            ?? branches.first
    }

    private var preview: String {
        guard let path = group.path, !trimmed.isEmpty,
              let branch = selectedBranch else {
            return "Folder and \(store.multiplexer.windowNoun) take the ticket name; the \(agent.displayName) session takes yours."
        }
        let dir = store.worktreeFolderName(
            repo: path,
            ticket: ticket.trimmingCharacters(in: .whitespacesAndNewlines),
            brief: WorktreeStore.sanitized(trimmed))
        return openClaude
            ? "Creates “\(dir)” from \(branch)"
            : "Creates “\(dir)” from \(branch) · opens a shell, no \(agent.displayName)"
    }

    private func commit() {
        guard let path = group.path, !trimmed.isEmpty else { return }
        if let p = store.createWorktree(repoPath: path, ticket: ticket, name: trimmed,
                                        baseBranch: selectedBranch, openClaude: openClaude,
                                        agent: agent) {
            problem = p
            return
        }
        onDone()
    }
}
