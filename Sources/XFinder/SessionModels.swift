import Foundation

/// A code agent whose chat sessions are stored as JSONL transcripts on disk.
enum SessionAgent: String, CaseIterable, Codable, Identifiable, Sendable {
    case claude
    case codex

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .claude: "Claude"
        case .codex: "Codex"
        }
    }

    /// Roots scanned recursively for `*.jsonl` session transcripts.
    var sessionRoots: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        switch self {
        case .claude:
            return [home.appendingPathComponent(".claude/projects")]
        case .codex:
            return [
                home.appendingPathComponent(".codex/sessions"),
                home.appendingPathComponent(".codex/archived_sessions"),
            ]
        }
    }
}

/// One message turn extracted from a transcript.
struct SessionMessage: Identifiable, Equatable, Sendable {
    enum Role: String, Sendable {
        case user, assistant
    }
    let id: Int
    let role: Role
    let text: String
}

/// List-row metadata for a session (cheap to compute — head read + file stat).
struct SessionSummary: Codable, Identifiable, Equatable, Sendable {
    let agent: SessionAgent
    let url: URL
    let title: String
    let project: String
    let projectPath: String?
    let modified: Date
    let sizeBytes: Int64
    /// Rough token estimate from file size (labelled as approximate in the UI).
    var approxTokens: Int { SessionParsing.estimateTokens(bytes: sizeBytes) }

    var id: String { url.path }
}

/// Full parse of one session for the viewer.
struct SessionTranscript: Equatable, Sendable {
    let messages: [SessionMessage]
    let exactTokens: Int
    let wasTruncated: Bool

    init(messages: [SessionMessage], exactTokens: Int, wasTruncated: Bool = false) {
        self.messages = messages
        self.exactTokens = exactTokens
        self.wasTruncated = wasTruncated
    }
}

struct SessionTranscriptLimits: Equatable, Sendable {
    var maximumReadBytes = 24 * 1_024 * 1_024
    var leadingReadBytes = 8 * 1_024 * 1_024
    var maximumMessages = 2_000
    var maximumCharacters = 2_000_000

    static let standard = SessionTranscriptLimits()
}

/// Pure transcript parsing — per-line extraction and estimation, split from
/// filesystem IO so it's unit-testable across both agents' JSONL schemas.
enum SessionParsing {
    /// ~4 characters per token, the common rough heuristic.
    static func estimateTokens(chars: Int) -> Int { chars / 4 }
    static func estimateTokens(bytes: Int64) -> Int { Int(bytes / 4) }

    /// True for machine-injected preambles (AGENTS.md/CLAUDE.md/system
    /// instructions) that shouldn't be used as a human-readable title.
    static func isPreamble(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefixes = [
            "# AGENTS.md", "# CLAUDE.md", "<INSTR", "<INSTRUCTIONS", "<system-reminder", "Caveat:",
            "<command-", "# Files mentioned by the user", "<environment_context", "<user_instructions",
            "# Files",
        ]
        return prefixes.contains { t.hasPrefix($0) }
    }

    /// Drops machine-injected preamble turns (AGENTS.md, attachments, system
    /// reminders) from a transcript so the viewer/summary start at the real
    /// first human prompt.
    static func stripPreamble(_ messages: [SessionMessage]) -> [SessionMessage] {
        messages.filter { !($0.role == .user && isPreamble($0.text)) }
    }

    /// Extracts a `(role, text)` message from one JSONL line, trying both the
    /// Claude and Codex schemas. Tool calls / non-message lines return nil.
    static func message(fromLine line: String) -> SessionMessage? {
        guard let data = line.data(using: .utf8),
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        // Claude: top-level type user/assistant, message.content str | [blocks]
        if let type = obj["type"] as? String, type == "user" || type == "assistant",
            let message = obj["message"] as? [String: Any]
        {
            if let text = textFromContent(message["content"]) {
                return SessionMessage(id: 0, role: type == "user" ? .user : .assistant, text: text)
            }
        }

        // Codex: payload.role user/assistant, payload.content [{text}]
        if let payload = obj["payload"] as? [String: Any],
            let role = payload["role"] as? String, role == "user" || role == "assistant",
            let text = textFromContent(payload["content"])
        {
            return SessionMessage(id: 0, role: role == "user" ? .user : .assistant, text: text)
        }

        return nil
    }

    /// cwd recorded in a line, if any (Claude top-level `cwd`, Codex
    /// `payload.cwd` on the session_meta line).
    static func cwd(fromLine line: String) -> String? {
        guard let data = line.data(using: .utf8),
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        if let cwd = obj["cwd"] as? String, !cwd.isEmpty { return cwd }
        if let payload = obj["payload"] as? [String: Any], let cwd = payload["cwd"] as? String, !cwd.isEmpty {
            return cwd
        }
        return nil
    }

    /// Flattens a message `content` (string, or array of text blocks) into plain
    /// text; nil when there's no textual content (e.g. pure tool blocks).
    static func textFromContent(_ content: Any?) -> String? {
        if let string = content as? String {
            return string.isEmpty ? nil : string
        }
        if let blocks = content as? [[String: Any]] {
            let parts = blocks.compactMap { block -> String? in
                guard let text = block["text"] as? String, !text.isEmpty else { return nil }
                return text
            }
            return parts.isEmpty ? nil : parts.joined(separator: "\n")
        }
        return nil
    }
}
