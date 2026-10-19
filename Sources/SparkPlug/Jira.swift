import Foundation
import Security

/// Moves the Jira ticket a session is for into the "working on it now" status
/// (e.g. "Current Active Issue") when Spark Plug starts a session. Talks to the
/// Jira Cloud REST API with an email + API token (Basic auth); the token lives
/// in the Keychain, the rest in UserDefaults.
struct JiraClient {
    let baseURL: URL
    let email: String
    let token: String

    /// First Jira-style issue key (`MP5-15184`) in each candidate, in order —
    /// candidates are typically the typed ticket, the worktree folder and its
    /// branch. Uppercase-only, so names like `v1-2` aren't mistaken for keys;
    /// the lookbehind lets a key follow `_` or `/` (`develop_feature_MP5-1_x`).
    static func issueKey(in candidates: [String]) -> String? {
        let regex = try! NSRegularExpression(pattern: "(?<![A-Za-z0-9])[A-Z][A-Z0-9]+-[0-9]+")
        for candidate in candidates {
            let range = NSRange(candidate.startIndex..., in: candidate)
            if let match = regex.firstMatch(in: candidate, range: range),
               let r = Range(match.range, in: candidate) {
                return String(candidate[r])
            }
        }
        return nil
    }

    /// Assigns `key` to the token's owner, then transitions it to the status
    /// named `status` (case-insensitive) — assigning first, as some workflows
    /// require an assignee to move a ticket. Steps already done are skipped.
    /// Returns a user-facing problem, or nil on success / no-op.
    func moveIssue(_ key: String, toStatus status: String) async -> String? {
        // Jira answers 404, not 401, when a token isn't accepted for this URL
        // (e.g. a scoped token used on the site URL): requests run anonymously
        // and the issue is invisible. `myself` tells that apart up front, and
        // gives the account to assign.
        let me: String
        do {
            guard let id = try await get("myself")["accountId"] as? String else {
                throw JiraError.http(401, "")
            }
            me = id
        } catch JiraError.http {
            return "Jira didn't accept the API token for \(baseURL.absoluteString) — "
                + "check the email and token, or for a scoped token set the site to "
                + "https://api.atlassian.com/ex/jira/<cloudId>."
        } catch {
            return "Couldn't reach Jira: \(error.localizedDescription)"
        }
        do {
            let issue = try await get("issue/\(key)?fields=status,assignee")
            let fields = issue["fields"] as? [String: Any] ?? [:]
            if (fields["assignee"] as? [String: Any])?["accountId"] as? String != me {
                try await send("PUT", "issue/\(key)/assignee", body: ["accountId": me])
            }
            if let current = (fields["status"] as? [String: Any])?["name"] as? String,
               current.caseInsensitiveCompare(status) == .orderedSame {
                return nil
            }
            let res = try await get("issue/\(key)/transitions")
            let transitions = res["transitions"] as? [[String: Any]] ?? []
            // Match on the target status, falling back to the transition's own
            // name — workflows often call the transition what the status is.
            let match = transitions.first { t in
                ((t["to"] as? [String: Any])?["name"] as? String)?
                    .caseInsensitiveCompare(status) == .orderedSame
            } ?? transitions.first { t in
                (t["name"] as? String)?.caseInsensitiveCompare(status) == .orderedSame
            }
            guard let id = match?["id"] as? String else {
                return "Jira has no way to move \(key) to “\(status)” from its current status."
            }
            _ = try await send("POST", "issue/\(key)/transitions",
                               body: ["transition": ["id": id]])
            return nil
        } catch let JiraError.http(code, _) where code == 401 || code == 403 {
            return "Jira wouldn't let you assign or move \(key) — check your permissions on its project."
        } catch JiraError.http(404, _) {
            return "Jira couldn't find \(key), or you don't have access to it."
        } catch {
            return "Couldn't move \(key) in Jira: \(error.localizedDescription)"
        }
    }

    private enum JiraError: LocalizedError {
        case http(Int, String)
        var errorDescription: String? {
            if case let .http(code, body) = self { return "HTTP \(code) \(body.prefix(200))" }
            return nil
        }
    }

    private func get(_ path: String) async throws -> [String: Any] {
        try await send("GET", path, body: nil)
    }

    @discardableResult
    private func send(_ method: String, _ path: String, body: [String: Any]?) async throws -> [String: Any] {
        guard let url = URL(string: "rest/api/3/\(path)", relativeTo: baseURL) else {
            throw URLError(.badURL)
        }
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.httpMethod = method
        let auth = Data("\(email):\(token)".utf8).base64EncodedString()
        req.setValue("Basic \(auth)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await URLSession.shared.data(for: req)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            throw JiraError.http(code, String(data: data, encoding: .utf8) ?? "")
        }
        // A successful transition answers 204 with no body.
        guard !data.isEmpty else { return [:] }
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }
}

/// The Jira API token, kept in the login Keychain rather than UserDefaults.
enum JiraToken {
    private static let service = "co.uk.kylescudder.spark-plug.jira"
    private static let account = "api-token"

    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    static func read() -> String {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// Stores `token`, or removes the entry when it's empty.
    static func write(_ token: String) {
        SecItemDelete(query as CFDictionary)
        guard !token.isEmpty else { return }
        var q = query
        q[kSecValueData as String] = Data(token.utf8)
        SecItemAdd(q as CFDictionary, nil)
    }
}
