import Foundation

struct ClaudeSession: Identifiable, Hashable {
    let id: String
    let fileURL: URL
    let customTitle: String?
    let firstMessage: String?
    let lastModified: Date
    let isLive: Bool
}

enum ClaudeProjects {
    static func sessionDir(for worktree: URL) -> URL {
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude")
            .appendingPathComponent("projects")
            .appendingPathComponent(encodePath(worktree.path))
    }

    /// Replicates Claude Code's project-dir encoding: every character that
    /// isn't alphanumeric or '-' becomes '-' (so '/', '_', '.', etc. all
    /// collapse to dashes; consecutive separators yield consecutive dashes).
    static func encodePath(_ path: String) -> String {
        String(path.map { ch in
            (ch.isLetter || ch.isNumber || ch == "-") ? ch : "-"
        })
    }

    static func sessionIds(for worktree: URL) -> Set<String> {
        let dir = sessionDir(for: worktree)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return Set(entries.filter { $0.pathExtension == "jsonl" }
            .map { $0.deletingPathExtension().lastPathComponent })
    }

    static func sessions(for worktree: URL) -> [ClaudeSession] {
        let dir = sessionDir(for: worktree)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        let live = LiveSessions.ids()

        return entries
            .filter { $0.pathExtension == "jsonl" }
            .map { url -> ClaudeSession in
                let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey])
                    .contentModificationDate) ?? .distantPast
                let id = url.deletingPathExtension().lastPathComponent
                let parsed = parse(at: url)
                return ClaudeSession(
                    id: id,
                    fileURL: url,
                    customTitle: parsed.title,
                    firstMessage: parsed.firstMessage,
                    lastModified: mtime,
                    isLive: live.contains(id)
                )
            }
            .sorted { $0.lastModified > $1.lastModified }
    }

    private static func parse(at url: URL) -> (title: String?, firstMessage: String?) {
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else { return (nil, nil) }
        var title: String?
        var firstMessage: String?
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let lineData = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any]
            else { continue }
            switch obj["type"] as? String {
            case "custom-title":
                if let t = obj["customTitle"] as? String, !t.isEmpty {
                    title = t
                }
            case "user":
                if firstMessage == nil,
                   (obj["isSidechain"] as? Bool ?? false) == false,
                   let message = obj["message"] as? [String: Any] {
                    if let s = message["content"] as? String {
                        firstMessage = clean(s)
                    } else if let arr = message["content"] as? [[String: Any]],
                              let first = arr.compactMap({ $0["text"] as? String }).first {
                        firstMessage = clean(first)
                    }
                }
            default: break
            }
            if title != nil && firstMessage != nil { break }
        }
        return (title, firstMessage)
    }

    private static func clean(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines)
         .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    }
}

enum LiveSessions {
    static func ids() -> Set<String> {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude")
            .appendingPathComponent("sessions")
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil
        ) else { return [] }
        var out = Set<String>()
        for url in entries where url.pathExtension == "json" {
            guard let data = try? Data(contentsOf: url),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let sid = obj["sessionId"] as? String
            else { continue }
            out.insert(sid)
        }
        return out
    }
}
