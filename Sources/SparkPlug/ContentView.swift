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
    @State private var sessionToDelete: ClaudeSession?
    @State private var worktreeToDelete: Worktree?
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
                        onCancel: { pendingNewSession = nil }
                    ) { name in
                        store.launchClaude(in: wt, newSessionName: name)
                        store.scan()
                        pendingNewSession = nil
                    }
                } else if let session = sessionToDelete {
                    let title = session.customTitle
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
                } else if let launch = store.pendingTmuxLaunch {
                    TmuxSessionPickerCard(launch: launch, store: store)
                }
            }
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            .shadow(radius: 24)
            .padding(24)
        }
    }

    private var isModalActive: Bool {
        pendingNewSession != nil || sessionToDelete != nil
            || worktreeToDelete != nil || store.pendingTmuxLaunch != nil
    }

    private var footer: some View {
        HStack {
            Text("\(store.worktrees.count) worktrees · \(groupedWorktrees.count) projects")
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
                NewWorktreePanel.shared.show()
            } label: {
                Label("New Worktree", systemImage: "plus.rectangle.on.folder")
            }
            .keyboardShortcut("n", modifiers: .command)
            .help("Create and provision a new worktree, then open Claude in it")
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
        }
        .padding(12)
    }

    /// Worktrees bucketed by source project, alphabetical, "Other" last.
    private var groupedWorktrees: [(project: String, path: String?, items: [Worktree])] {
        Dictionary(grouping: store.worktrees, by: { $0.projectName })
            .map { (project: $0.key, path: $0.value.first?.projectPath, items: $0.value) }
            .sorted {
                if $0.project == Worktree.otherProjectName { return false }
                if $1.project == Worktree.otherProjectName { return true }
                return $0.project.localizedCaseInsensitiveCompare($1.project) == .orderedAscending
            }
    }

    private var list: some View {
        Group {
            if store.worktrees.isEmpty {
                ContentUnavailableView(
                    "No worktrees",
                    systemImage: "tray",
                    description: Text("Pick a folder containing subdirectories.")
                )
            } else {
                // A plain VStack instead of List: NSTableView-backed Lists
                // snap rather than animate conditional section content.
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(groupedWorktrees, id: \.project) { group in
                            projectHeader(group.project, path: group.path,
                                          count: group.items.count)
                            if !collapsedProjects.contains(group.project) {
                                ForEach(group.items) { wt in
                                    row(for: wt)
                                        .padding(.horizontal, 12)
                                    if wt.id != group.items.last?.id {
                                        Divider().padding(.leading, 40)
                                    }
                                }
                                .transition(.opacity)
                            }
                        }
                    }
                    .animation(.easeInOut(duration: 0.2), value: collapsedProjects)
                    .padding(.vertical, 4)
                }
            }
        }
    }

    private func toggleCollapsed(_ name: String) {
        if collapsedProjects.contains(name) {
            collapsedProjects.remove(name)
        } else {
            collapsedProjects.insert(name)
        }
        UserDefaults.standard.set(Array(collapsedProjects), forKey: Self.collapsedKey)
    }

    @ViewBuilder
    private func projectHeader(_ name: String, path: String?, count: Int) -> some View {
        Button {
            toggleCollapsed(name)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(collapsedProjects.contains(name) ? 0 : 90))
                Image(systemName: name == Worktree.otherProjectName
                      ? "folder" : "shippingbox.fill")
                    .foregroundStyle(name == Worktree.otherProjectName
                                     ? AnyShapeStyle(.secondary) : AnyShapeStyle(.yellow))
                Text(name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                Text("\(count)")
                    .font(.caption2)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Color.secondary.opacity(0.15), in: Capsule())
                    .foregroundStyle(.secondary)
                Spacer()
                if let path {
                    Text(path)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color.secondary.opacity(0.07))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(path ?? name)
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
                    if wt.hasClaudeSession {
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
        Menu {
            if sessions.isEmpty {
                Text("No sessions yet")
            } else {
                ForEach(sessions) { s in
                    Menu {
                        Button {
                            store.launchClaude(in: wt, resumeSessionId: s.id)
                        } label: {
                            Label("Resume", systemImage: "arrow.uturn.forward")
                        }
                        .disabled(s.isLive)

                        Button {
                            store.revealSessionInFinder(s)
                        } label: {
                            Label("Show Transcript in Finder", systemImage: "doc.text.magnifyingglass")
                        }

                        Divider()

                        Button(role: .destructive) {
                            sessionToDelete = s
                        } label: {
                            Label("Delete…", systemImage: "trash")
                        }
                        .disabled(s.isLive)
                    } label: {
                        Text(sessionLabel(s))
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

    private func sessionTitle(_ s: ClaudeSession) -> String {
        if let t = s.customTitle, !t.isEmpty { return t }
        if let first = s.firstMessage, !first.isEmpty {
            return first.count > 60 ? String(first.prefix(60)) + "…" : first
        }
        return String(s.id.prefix(8))
    }

    private func sessionLabel(_ s: ClaudeSession) -> String {
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
        .help("\(wt.sessionCount) Claude session\(wt.sessionCount == 1 ? "" : "s") for this folder")
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

/// In-popover replacement for the tmux session confirmationDialog.
private struct TmuxSessionPickerCard: View {
    let launch: PendingTmuxLaunch
    @ObservedObject var store: WorktreeStore

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "terminal")
                    .foregroundStyle(.yellow)
                Text("Which tmux session?").font(.headline)
            }
            Text("Multiple tmux sessions are running. Choose where to open the new Claude window.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 6) {
                ForEach(launch.sessionNames, id: \.self) { name in
                    Button {
                        store.completePendingLaunch(session: name)
                    } label: {
                        Text(name).frame(maxWidth: .infinity)
                    }
                }
                Button {
                    store.completePendingLaunch(session: nil)
                } label: {
                    Text("New tmux Session").frame(maxWidth: .infinity)
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { store.pendingTmuxLaunch = nil }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 400)
    }
}

private struct NewSessionCard: View {
    let worktree: Worktree
    let onCancel: () -> Void
    let onStart: (String) -> Void

    @State private var name: String = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "sparkle")
                    .foregroundStyle(.yellow)
                Text("New Claude session").font(.headline)
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

    private func commit() {
        guard !trimmed.isEmpty else { return }
        onStart(trimmed)
    }
}

/// Editable, autocompleting dropdown (NSComboBox) — type to filter, or pick
/// from the repo's branches.
private struct BranchComboBox: NSViewRepresentable {
    @Binding var text: String
    var items: [String]

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    func makeNSView(context: Context) -> NSComboBox {
        let box = NSComboBox()
        box.usesDataSource = false
        box.completes = true
        box.numberOfVisibleItems = 12
        box.delegate = context.coordinator
        return box
    }

    func updateNSView(_ box: NSComboBox, context: Context) {
        let current = box.objectValues.compactMap { $0 as? String }
        if current != items {
            box.removeAllItems()
            box.addItems(withObjectValues: items)
        }
        if box.stringValue != text {
            box.stringValue = text
        }
    }

    final class Coordinator: NSObject, NSComboBoxDelegate {
        let text: Binding<String>
        init(text: Binding<String>) { self.text = text }

        func controlTextDidChange(_ notification: Notification) {
            guard let box = notification.object as? NSComboBox else { return }
            text.wrappedValue = box.stringValue
        }

        func comboBoxSelectionDidChange(_ notification: Notification) {
            guard let box = notification.object as? NSComboBox,
                  let value = box.objectValueOfSelectedItem as? String else { return }
            text.wrappedValue = value
        }
    }
}

struct NewWorktreeForm: View {
    @ObservedObject var store: WorktreeStore
    let onClose: () -> Void

    @State private var sourceRepo: String = ""
    @State private var rememberDefault: Bool = false
    @State private var ticket: String = ""
    @State private var briefName: String = ""
    @State private var baseBranch: String = "develop"
    @State private var showAdvanced = false
    @State private var setupCommand: String = ""
    @State private var tmuxSessions: [String] = []
    @State private var tmuxChoice: TmuxChoice = .automatic
    @State private var branchOptions: [String] = []
    @State private var branchError: String?
    @State private var nameError: String?
    @FocusState private var ticketFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "plus.rectangle.on.folder")
                    .foregroundStyle(.yellow)
                Text("New worktree").font(.headline)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Source repository").font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    TextField("/path/to/repo", text: $sourceRepo)
                        .textFieldStyle(.roundedBorder)
                    Button("Choose…") {
                        if let picked = store.pickSourceRepo(startingAt: sourceRepo) {
                            sourceRepo = picked
                        }
                    }
                }
                Toggle("Remember as default", isOn: $rememberDefault)
                    .font(.caption)
            }

            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Ticket (optional)").font(.caption).foregroundStyle(.secondary)
                    TextField("MP5-12345", text: $ticket)
                        .textFieldStyle(.roundedBorder)
                        .focused($ticketFocused)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Brief name").font(.caption).foregroundStyle(.secondary)
                    TextField("FixAuthTimeout", text: $briefName)
                        .textFieldStyle(.roundedBorder)
                }
            }
            if let err = nameError {
                Label(err, systemImage: "exclamationmark.triangle")
                    .font(.caption2)
                    .foregroundStyle(.red)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Base branch").font(.caption).foregroundStyle(.secondary)
                BranchComboBox(text: $baseBranch, items: branchOptions)
                    .frame(height: 24)
                if let err = branchError {
                    Label(err, systemImage: "exclamationmark.triangle")
                        .font(.caption2)
                        .foregroundStyle(.red)
                }
            }

            if !t(sourceRepo).isEmpty && !willUseSetupScript {
                Label("No setup script for this repo (or no ticket) — a plain `git worktree add` will be used.",
                      systemImage: "info.circle")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if tmuxSessions.count > 1 {
                VStack(alignment: .leading, spacing: 6) {
                    Text("tmux session").font(.caption).foregroundStyle(.secondary)
                    Picker("tmux session", selection: $tmuxChoice) {
                        ForEach(tmuxSessions, id: \.self) { name in
                            Text(name).tag(TmuxChoice.session(name))
                        }
                        Text("New session").tag(TmuxChoice.newSession)
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                }
            }

            DisclosureGroup("Advanced", isExpanded: $showAdvanced) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Setup command (run in source repo). Placeholders: {ticket} {brief} {base}")
                        .font(.caption2).foregroundStyle(.secondary)
                    TextField(WorktreeStore.defaultSetupCommand, text: $setupCommand)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.caption, design: .monospaced))
                }
                .padding(.top, 4)
            }
            .font(.caption)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { onClose() }
                    .keyboardShortcut(.cancelAction)
                Button("Start") { commit() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!isValid)
            }
        }
        .padding(20)
        .frame(width: 460)
        .onAppear {
            sourceRepo = store.defaultSourceRepo
            rememberDefault = store.defaultSourceRepo.isEmpty
            setupCommand = store.setupCommandTemplate
            tmuxSessions = store.tmuxSessionNames()
            if let first = tmuxSessions.first, tmuxSessions.count > 1 {
                tmuxChoice = .session(first)
            }
            loadBranches()
            ticketFocused = true
        }
        .onChange(of: sourceRepo) { loadBranches() }
        .onChange(of: baseBranch) { branchError = nil }
        .onChange(of: ticket) { nameError = nil }
        .onChange(of: briefName) { nameError = nil }
    }

    /// Refreshes the branch dropdown for the current repo and defaults the
    /// base to the first usual suspect that exists.
    private func loadBranches() {
        let repo = (t(sourceRepo) as NSString).expandingTildeInPath
        branchOptions = store.branches(in: repo)
        branchError = nil
        if let preferred = ["develop", "main", "master"].first(where: branchOptions.contains) {
            baseBranch = preferred
        } else if let first = branchOptions.first {
            baseBranch = first
        }
    }

    private func t(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isValid: Bool {
        !t(sourceRepo).isEmpty && !t(briefName).isEmpty
    }

    /// Mirrors the store's decision so the form can hint at the fallback.
    private var willUseSetupScript: Bool {
        store.willUseSetupScript(
            repo: (t(sourceRepo) as NSString).expandingTildeInPath,
            ticket: t(ticket)
        )
    }

    private func commit() {
        guard isValid else { return }
        let repo = t(sourceRepo)
        let base = t(baseBranch).isEmpty ? "develop" : t(baseBranch)
        let repoExpanded = (repo as NSString).expandingTildeInPath
        guard store.branchExists(in: repoExpanded, branch: base) else {
            branchError = "Branch “\(base)” doesn't exist in this repository."
            return
        }
        // The fallback runs `git worktree add -b <name>`, which dies after the
        // form is gone if the branch lingers — catch it here instead.
        let dirName = t(ticket).isEmpty ? t(briefName) : "\(t(ticket))_\(t(briefName))"
        if !willUseSetupScript, store.localBranchExists(in: repoExpanded, branch: dirName) {
            nameError = "Branch “\(dirName)” already exists here — pick another name or delete that branch first."
            return
        }
        if rememberDefault { store.defaultSourceRepo = repo }
        if t(setupCommand) != store.setupCommandTemplate && !t(setupCommand).isEmpty {
            store.setupCommandTemplate = t(setupCommand)
        }
        store.createWorktree(
            sourceRepo: repo,
            ticket: t(ticket),
            briefName: t(briefName),
            baseBranch: base,
            tmuxChoice: tmuxChoice
        )
        onClose()
    }
}
