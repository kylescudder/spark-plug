import Foundation

/// A coding agent Spark Plug can launch into a worktree. Raw values match
/// Herdr's agent-detection "kind" so an agent launched through the Herdr
/// backend is recognised by Herdr's own status detection.
///
/// Launching works for every case. Resume and per-worktree session history are
/// only wired for agents whose on-disk format has been verified — Claude
/// (JSONL transcripts) and OpenCode (SQLite). The rest launch and, once their
/// format is confirmed, gain a provider without touching call sites.
enum Agent: String, CaseIterable, Identifiable, Hashable {
    case claude, codex, gemini, opencode, cursor, copilot, amp, grok, droid,
         kimi, cline, devin, kilo, kiro, qodercli, pi, agy, hermes, maki

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex: return "Codex"
        case .gemini: return "Gemini"
        case .opencode: return "OpenCode"
        case .cursor: return "Cursor"
        case .copilot: return "Copilot"
        case .amp: return "Amp"
        case .grok: return "Grok"
        case .droid: return "Droid"
        case .kimi: return "Kimi"
        case .cline: return "Cline"
        case .devin: return "Devin"
        case .kilo: return "Kilo Code"
        case .kiro: return "Kiro"
        case .qodercli: return "Qoder"
        case .pi: return "Pi"
        case .agy: return "Agy"
        case .hermes: return "Hermes"
        case .maki: return "Maki"
        }
    }

    /// The executable typed to launch the agent. Mostly the raw kind; the few
    /// exceptions are known, and the unverified niche agents assume `rawValue`
    /// (harmless — a wrong name just fails visibly in the terminal, and the
    /// mapping is a one-line fix).
    var executable: String {
        switch self {
        case .cursor: return "cursor-agent"
        case .qodercli: return "qoder"
        default: return rawValue
        }
    }

    /// Command that starts a new session, naming it when the agent supports
    /// naming (only Claude today; for the rest the typed name still labels the
    /// multiplexer window/workspace, it just isn't passed to the agent).
    func newSessionCommand(name: String?) -> String {
        switch self {
        case .claude:
            if let name, !name.isEmpty { return "\(executable) -n \(Agent.shq(name))" }
            return executable
        default:
            return executable
        }
    }

    /// Command that resumes session `id`, or nil when resume isn't wired for
    /// this agent yet.
    func resumeCommand(sessionId: String) -> String? {
        switch self {
        case .claude: return "\(executable) --resume \(Agent.shq(sessionId))"
        case .opencode: return "\(executable) --session \(Agent.shq(sessionId))"
        default: return nil
        }
    }

    var supportsResume: Bool { resumeCommand(sessionId: "x") != nil }

    /// Reads this agent's past sessions for a worktree. Unverified agents use
    /// `NullSessionProvider` (no history) rather than a guessed parser.
    var sessionProvider: AgentSessionProvider {
        switch self {
        case .claude: return ClaudeSessionProvider()
        case .opencode: return OpenCodeSessionProvider()
        default: return NullSessionProvider()
        }
    }

    /// POSIX single-quote for embedding a value in a typed shell command.
    static func shq(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// One past session of some agent in a worktree. `fileURL` is nil for stores
/// that aren't file-backed (e.g. OpenCode's database); such sessions can't be
/// revealed in Finder or deleted from disk here.
struct AgentSession: Identifiable, Hashable {
    let id: String
    let agent: Agent
    let title: String?
    let firstMessage: String?
    let lastModified: Date
    let isLive: Bool
    let fileURL: URL?

    var canReveal: Bool { fileURL != nil }
    var canDelete: Bool { fileURL != nil }
}

/// Reads (and, where possible, deletes) an agent's on-disk sessions.
protocol AgentSessionProvider {
    func sessions(for worktree: URL) -> [AgentSession]
    /// Removes a session's transcript. Returns false when unsupported or failed.
    func deleteSession(_ session: AgentSession) -> Bool
}

extension AgentSessionProvider {
    func deleteSession(_ session: AgentSession) -> Bool { false }
}

/// Placeholder for agents whose session format isn't verified yet: they still
/// launch, they just show no history.
struct NullSessionProvider: AgentSessionProvider {
    func sessions(for worktree: URL) -> [AgentSession] { [] }
}

/// The merged session history for a worktree across every agent, newest first.
/// Only Claude and OpenCode do real work; the rest return [] instantly.
enum AgentSessions {
    static func all(for worktree: URL) -> [AgentSession] {
        Agent.allCases
            .flatMap { $0.sessionProvider.sessions(for: worktree) }
            .sorted { $0.lastModified > $1.lastModified }
    }
}

// MARK: - OpenCode (SQLite)

/// Reads OpenCode's `session` table, filtered to a worktree directory. Opens
/// read-only (`mode=ro`) — a safe concurrent WAL reader alongside a running
/// OpenCode. NOT `immutable`: that flag ignores the `-wal` file, which is
/// exactly where a just-created session lives before it's checkpointed, so an
/// immutable read would miss the newest sessions entirely.
struct OpenCodeSessionProvider: AgentSessionProvider {
    func sessions(for worktree: URL) -> [AgentSession] {
        let fm = FileManager.default
        guard let sqlite = Self.sqlitePath, fm.fileExists(atPath: Self.dbPath) else { return [] }
        let uri = "file:\(Self.dbPath)?mode=ro"
        let sql = """
        SELECT id, title, time_updated FROM session \
        WHERE directory = '\(Self.sqlEscape(worktree.path))' \
        AND parent_id IS NULL AND time_archived IS NULL \
        ORDER BY time_updated DESC;
        """
        let res = Self.run(sqlite, [uri, "-json", sql])
        guard res.status == 0,
              let data = res.output.data(using: .utf8),
              let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return [] }
        return rows.compactMap { row in
            guard let id = row["id"] as? String else { return nil }
            let title = (row["title"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let raw = (row["time_updated"] as? NSNumber)?.doubleValue ?? 0
            // OpenCode stamps epoch milliseconds; tolerate seconds just in case.
            let seconds = raw > 1_000_000_000_000 ? raw / 1000 : raw
            return AgentSession(
                id: id, agent: .opencode, title: title, firstMessage: nil,
                lastModified: Date(timeIntervalSince1970: seconds),
                isLive: false, fileURL: nil)
        }
    }

    private static var dbPath: String {
        (("~/.local/share/opencode/opencode.db" as NSString).expandingTildeInPath)
    }

    private static var sqlitePath: String? {
        ["/usr/bin/sqlite3", "/opt/homebrew/bin/sqlite3", "/usr/local/bin/sqlite3"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private static func sqlEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "'", with: "''")
    }

    private static func run(_ path: String, _ args: [String]) -> (status: Int32, output: String) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)
        proc.arguments = args
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        do { try proc.run(); proc.waitUntilExit() } catch { return (-1, "") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return (proc.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }
}
