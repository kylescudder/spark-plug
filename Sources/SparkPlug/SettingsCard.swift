import SwiftUI

/// Settings window content: app version plus the store's persisted settings.
/// Edits are held locally and committed on Save so `rootPath.didSet` doesn't
/// rescan on every keystroke.
struct SettingsCard: View {
    @ObservedObject var store: WorktreeStore
    @Environment(\.dismiss) private var dismiss

    @State private var rootPath: String = ""
    @State private var setupCommand: String = ""

    private var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "gearshape.fill")
                    .foregroundStyle(.yellow)
                Text("Settings").font(.headline)
                Spacer()
                Text("v\(version)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help("Spark Plug version")
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Worktrees root").font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    TextField("~/worktrees", text: $rootPath)
                        .textFieldStyle(.roundedBorder)
                    Button("Browse…") {
                        if let path = WorktreeStore.promptForFolder(
                            message: "Pick the folder that contains your worktrees") {
                            rootPath = path
                        }
                    }
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Setup command").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Reset to default") {
                        setupCommand = WorktreeStore.defaultSetupCommand
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .disabled(setupCommand == WorktreeStore.defaultSetupCommand)
                }
                TextField("./scripts/setup-worktree.sh {ticket} {brief} {base}", text: $setupCommand)
                    .textFieldStyle(.roundedBorder)
                Text("Runs in the source repo when creating a worktree. {ticket}, {brief} and {base} are substituted.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { commit() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(trimmedRoot.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 440)
        .onAppear {
            rootPath = store.rootPath
            setupCommand = store.setupCommandTemplate
        }
    }

    private var trimmedRoot: String {
        rootPath.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func commit() {
        let root = (trimmedRoot as NSString).expandingTildeInPath
        if root != store.rootPath {
            store.rootPath = root
        }
        let cmd = setupCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        store.setupCommandTemplate = cmd.isEmpty ? WorktreeStore.defaultSetupCommand : cmd
        dismiss()
    }
}
