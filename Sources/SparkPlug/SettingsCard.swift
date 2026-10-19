import SwiftUI

/// Settings window content: app version plus the store's persisted settings.
/// Edits are held locally and committed on Save so `rootPath.didSet` doesn't
/// rescan on every keystroke.
struct SettingsCard: View {
    @ObservedObject var store: WorktreeStore
    @Environment(\.dismiss) private var dismiss

    @State private var rootPath: String = ""
    @State private var setupCommand: String = ""
    @State private var postStartScript: String = ""
    @State private var multiplexer: Multiplexer = .tmux
    @State private var agent: Agent = .claude
    @State private var openClaudeOnStart: Bool = true
    @State private var jiraBaseURL: String = ""
    @State private var jiraEmail: String = ""
    @State private var jiraToken: String = ""
    @State private var jiraStatus: String = ""

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
                Text("Terminal multiplexer").font(.caption).foregroundStyle(.secondary)
                Picker("Terminal multiplexer", selection: $multiplexer) {
                    ForEach(Multiplexer.allCases) { m in
                        Text(m.displayName).tag(m)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Text("Where new Claude sessions open. Either reuses a running session, or asks when several are open.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Default agent").font(.caption).foregroundStyle(.secondary)
                Picker("Default agent", selection: $agent) {
                    ForEach(Agent.allCases) { a in Text(a.displayName).tag(a) }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                Text("Which coding agent new worktrees launch. Repos and individual worktrees can override it.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 6) {
                Toggle("Launch agent on start", isOn: $openClaudeOnStart)
                    .toggleStyle(.checkbox)
                Text("Global default for new worktrees. Repos and individual worktrees can override it; off leaves a ready shell instead.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
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

            VStack(alignment: .leading, spacing: 6) {
                Text("Post-start script").font(.caption).foregroundStyle(.secondary)
                TextField("bun dev", text: $postStartScript)
                    .textFieldStyle(.roundedBorder)
                Text("Global default, run inside the new worktree after setup and before the agent. Repos and individual worktrees can override it; leave empty to run nothing. {ticket}, {brief} and {base} are substituted — e.g. claude -n \"{ticket}-{brief}\" names a session even with no setup script.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Jira").font(.caption).foregroundStyle(.secondary)
                TextField("https://your-site.atlassian.net", text: $jiraBaseURL)
                    .textFieldStyle(.roundedBorder)
                HStack(spacing: 8) {
                    TextField("Email", text: $jiraEmail)
                        .textFieldStyle(.roundedBorder)
                    SecureField("API token", text: $jiraToken)
                        .textFieldStyle(.roundedBorder)
                }
                TextField(WorktreeStore.defaultJiraActiveStatus, text: $jiraStatus)
                    .textFieldStyle(.roundedBorder)
                Text("When a session starts, the ticket key in its ticket, folder or branch (e.g. MP5-123) is moved to this status. Leave any field empty to turn it off. The token is kept in your Keychain.")
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
            postStartScript = store.postStartScriptGlobal
            multiplexer = store.multiplexer
            agent = store.defaultAgent
            openClaudeOnStart = store.openClaudeOnStartGlobal
            jiraBaseURL = store.jiraBaseURL
            jiraEmail = store.jiraEmail
            jiraToken = store.jiraToken
            jiraStatus = store.jiraActiveStatus
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
        let postStart = postStartScript.trimmingCharacters(in: .whitespacesAndNewlines)
        if postStart != store.postStartScriptGlobal {
            store.postStartScriptGlobal = postStart
        }
        if multiplexer != store.multiplexer {
            store.multiplexer = multiplexer
        }
        if agent != store.defaultAgent {
            store.defaultAgent = agent
        }
        if openClaudeOnStart != store.openClaudeOnStartGlobal {
            store.openClaudeOnStartGlobal = openClaudeOnStart
        }
        let trim = { (s: String) in s.trimmingCharacters(in: .whitespacesAndNewlines) }
        if trim(jiraBaseURL) != store.jiraBaseURL { store.jiraBaseURL = trim(jiraBaseURL) }
        if trim(jiraEmail) != store.jiraEmail { store.jiraEmail = trim(jiraEmail) }
        if trim(jiraToken) != store.jiraToken { store.jiraToken = trim(jiraToken) }
        if trim(jiraStatus) != store.jiraActiveStatus { store.jiraActiveStatus = trim(jiraStatus) }
        dismiss()
    }
}
