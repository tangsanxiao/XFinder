import Foundation
import SQLite3

/// Best-effort bridge to Codex's local display titles. Codex stores generated
/// and renamed thread names separately from the JSONL transcript, so the first
/// user message is only a fallback title.
enum CodexThreadTitleCatalog {
    static func load(codexDirectory: URL? = nil) -> [String: String] {
        let directory =
            codexDirectory
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex", isDirectory: true)
        return load(
            catalogDatabaseURLs: [
                directory.appendingPathComponent("sqlite/codex-dev.db"),
                directory.appendingPathComponent("sqlite/codex.db"),
            ],
            stateDatabaseURLs: [
                directory.appendingPathComponent("state_5.sqlite"),
                directory.appendingPathComponent("sqlite/state_5.sqlite"),
            ])
    }

    static func load(
        catalogDatabaseURLs: [URL],
        stateDatabaseURLs: [URL]
    ) -> [String: String] {
        var titles: [String: String] = [:]

        // Older state databases are fallback-only; the root state database is
        // normally newer, so process the caller's preferred URL last.
        for url in stateDatabaseURLs.reversed() {
            merge(
                rows(
                    at: url,
                    sql: "SELECT id, title FROM threads WHERE TRIM(title) <> ''"),
                into: &titles)
            merge(
                rows(
                    at: url,
                    sql: "SELECT id, name FROM threads WHERE name IS NOT NULL AND TRIM(name) <> ''"),
                into: &titles)
        }

        // The desktop catalog is the final authority: display_title reflects
        // Codex's generated or user-renamed title shown in its sidebar.
        for url in catalogDatabaseURLs.reversed() {
            merge(
                rows(
                    at: url,
                    sql: """
                        SELECT thread_id, display_title
                        FROM local_thread_catalog
                        WHERE host_id = 'local'
                          AND missing_candidate = 0
                          AND TRIM(display_title) <> ''
                        """),
                into: &titles)
        }
        return titles
    }

    static func threadID(fromRolloutURL url: URL) -> String? {
        let stem = url.deletingPathExtension().lastPathComponent
        guard stem.count >= 36 else { return nil }
        let candidate = String(stem.suffix(36))
        return UUID(uuidString: candidate) == nil ? nil : candidate.lowercased()
    }

    private static func merge(_ rows: [(String, String)], into titles: inout [String: String]) {
        for (id, rawTitle) in rows {
            guard let title = normalizedTitle(rawTitle) else { continue }
            titles[id.lowercased()] = title
        }
    }

    private static func normalizedTitle(_ rawTitle: String) -> String? {
        let title = rawTitle.split(whereSeparator: \Character.isNewline).map(String.init)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return nil }
        return title.count > 140 ? String(title.prefix(140)) + "…" : title
    }

    private static func rows(at url: URL, sql: String) -> [(String, String)] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        var database: OpaquePointer?
        guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK,
            let database
        else {
            if let database { sqlite3_close(database) }
            return []
        }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 50)

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            return []
        }
        defer { sqlite3_finalize(statement) }

        var result: [(String, String)] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let idBytes = sqlite3_column_text(statement, 0),
                let titleBytes = sqlite3_column_text(statement, 1)
            else { continue }
            result.append((String(cString: idBytes), String(cString: titleBytes)))
        }
        return result
    }
}
