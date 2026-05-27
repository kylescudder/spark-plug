import SwiftUI

private let relativeFormatter: RelativeDateTimeFormatter = {
    let f = RelativeDateTimeFormatter()
    f.unitsStyle = .abbreviated
    return f
}()

struct ContentView: View {
    @StateObject private var store = WorktreeStore()
    @State private var pendingNewSession: Worktree?

    var body: some View {
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
        .sheet(item: $pendingNewSession) { wt in
            NewSessionSheet(worktree: wt) { name in
                store.launchClaude(in: wt, newSessionName: name)
                store.scan()
            }
        }
    }

    private var footer: some View {
        HStack {
            Text("\(store.worktrees.count) worktrees")
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

    private var list: some View {
        Group {
            if store.worktrees.isEmpty {
                ContentUnavailableView(
                    "No worktrees",
                    systemImage: "tray",
                    description: Text("Pick a folder containing subdirectories.")
                )
            } else {
                List(store.worktrees) { wt in
                    row(for: wt)
                }
                .listStyle(.inset)
            }
        }
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
                store.revealInFinder(wt)
            } label: {
                Image(systemName: "magnifyingglass")
            }
            .help("Reveal in Finder")
            .buttonStyle(.borderless)

            continueMenu(for: wt)

            Button {
                pendingNewSession = wt
            } label: {
                Label("New", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .help("Start a new Claude session")
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func continueMenu(for wt: Worktree) -> some View {
        let sessions = ClaudeProjects.sessions(for: wt.url)
        Menu {
            if sessions.isEmpty {
                Text("No sessions yet")
            } else {
                ForEach(sessions) { s in
                    Button {
                        store.launchClaude(in: wt, resumeSessionId: s.id)
                    } label: {
                        Text(sessionLabel(s))
                    }
                    .disabled(s.isLive)
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

    private func sessionLabel(_ s: ClaudeSession) -> String {
        let when = relativeFormatter.localizedString(for: s.lastModified, relativeTo: Date())
        let title: String = {
            if let t = s.customTitle, !t.isEmpty { return t }
            if let first = s.firstMessage, !first.isEmpty {
                return first.count > 60 ? String(first.prefix(60)) + "…" : first
            }
            return String(s.id.prefix(8))
        }()
        let live = s.isLive ? "● live · " : ""
        return "\(live)\(title)  ·  \(when)"
    }

    @ViewBuilder
    private func sessionBadge(_ wt: Worktree) -> some View {
        let label: String = {
            if let last = wt.lastSessionAt {
                let when = relativeFormatter.localizedString(for: last, relativeTo: Date())
                return "\(wt.sessionCount) session\(wt.sessionCount == 1 ? "" : "s") · \(when)"
            }
            return "\(wt.sessionCount) session\(wt.sessionCount == 1 ? "" : "s")"
        }()
        HStack(spacing: 3) {
            Image(systemName: "sparkle")
            Text(label)
        }
        .font(.caption2)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Color.orange.opacity(0.18), in: Capsule())
        .foregroundStyle(.orange)
        .help("Claude session history exists for this folder")
    }
}

private struct NewSessionSheet: View {
    let worktree: Worktree
    let onStart: (String) -> Void

    @Environment(\.dismiss) private var dismiss
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
                Button("Cancel", role: .cancel) { dismiss() }
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
        dismiss()
    }
}
