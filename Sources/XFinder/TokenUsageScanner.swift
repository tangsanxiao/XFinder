import Foundation
import SQLite3

struct TokenUsageScanProgress: Equatable, Sendable {
    var filesDone: Int
    var filesTotal: Int
    var bytesRead: Int64
}

struct TokenUsageScanMetrics: Equatable, Sendable {
    var reusedFiles: Int
    var scannedFiles: Int
    var bytesRead: Int64
}

struct TokenUsageScanResult: Sendable {
    var ledger: UsageLedger
    var metrics: TokenUsageScanMetrics
}

/// A tool plus the roots scanned for its logs. Tests pass temp directories so
/// the scanner never touches real session stores.
struct TokenUsageScanSource: Sendable {
    let tool: UsageTool
    let roots: [URL]
}

/// Scans each tool's local logs into the persisted usage ledger. Append-only
/// JSONL logs are read incrementally from the last consumed offset
/// (`UsageFileContribution.offset`); whole-document sources (JSON exports,
/// snapshot+patch chat sessions, SQLite, cumulative-snapshot logs) are
/// re-read whole and their contribution replaced, never merged. Everything
/// runs off the main actor, line-based files are read as bounded chunks
/// (never whole-file), and cancellation between files still persists the
/// files already scanned.
enum TokenUsageScanner {
    /// Whole-file sources are capped; anything larger is skipped rather than
    /// loaded into memory.
    private static let maximumWholeFileBytes: Int64 = 256 * 1024 * 1024

    static func scan(
        sources: [TokenUsageScanSource]? = nil,
        ledgerURL: URL,
        retentionDays: Int,
        progress: (@Sendable (TokenUsageScanProgress) -> Void)? = nil
    ) async -> TokenUsageScanResult {
        await Task.detached(priority: .utility) {
            let sources = sources ?? UsageTool.allCases.map { TokenUsageScanSource(tool: $0, roots: $0.scanRoots) }
            var ledger = loadLedger(at: ledgerURL) ?? UsageLedger()
            let candidates = enumerateFiles(sources: sources)
            var metrics = TokenUsageScanMetrics(reusedFiles: 0, scannedFiles: 0, bytesRead: 0)
            let fileManager = FileManager.default

            for (index, candidate) in candidates.enumerated() {
                if Task.isCancelled { break }
                let key = UsageFileKey.make(tool: candidate.tool, url: candidate.url)
                let strategy = candidate.tool.strategy(forFile: candidate.url)
                if let existing = ledger.files[key], existing.offset == candidate.sizeBytes,
                    strategy == .incrementalLines || existing.modified == candidate.modified
                {
                    metrics.reusedFiles += 1
                } else {
                    let startOffset: Int64
                    var mergedDays: [String: [String: UsageTotals]]
                    if strategy == .incrementalLines, let existing = ledger.files[key],
                        candidate.sizeBytes > existing.offset
                    {
                        // Append-only growth: read only the new tail.
                        startOffset = existing.offset
                        mergedDays = existing.days
                    } else {
                        // New file, whole-file source, or a shrunk/rewritten
                        // log: rescan from zero and replace the contribution to
                        // avoid double counting.
                        startOffset = 0
                        mergedDays = [:]
                    }
                    if let parsed = parseFile(
                        url: candidate.url,
                        tool: candidate.tool,
                        from: startOffset,
                        fileSize: candidate.sizeBytes,
                        into: &mergedDays
                    ) {
                        var entry = ledger.files[key] ?? UsageFileContribution(offset: 0, modified: candidate.modified)
                        entry.offset = parsed.offset
                        entry.modified = candidate.modified
                        entry.days = mergedDays
                        ledger.files[key] = entry
                        if let rateLimit = parsed.rateLimit,
                            rateLimit.capturedAt > ledger.rateLimits[candidate.tool.rawValue]?.capturedAt
                                ?? .distantPast
                        {
                            ledger.rateLimits[candidate.tool.rawValue] = rateLimit
                        }
                        metrics.scannedFiles += 1
                        metrics.bytesRead += candidate.sizeBytes - startOffset
                    }
                }
                progress?(
                    TokenUsageScanProgress(
                        filesDone: index + 1,
                        filesTotal: candidates.count,
                        bytesRead: metrics.bytesRead
                    ))
            }

            ledger.prune(olderThan: UsageDayKey.offset(-max(1, retentionDays)))
            saveLedger(ledger, at: ledgerURL, fileManager: fileManager)
            return TokenUsageScanResult(ledger: ledger, metrics: metrics)
        }.value
    }

    static func loadLedger(at url: URL) -> UsageLedger? {
        guard let data = try? Data(contentsOf: url),
            let ledger = try? JSONDecoder().decode(UsageLedger.self, from: data),
            ledger.version == UsageLedger.currentVersion
        else { return nil }
        return ledger
    }

    private static func saveLedger(_ ledger: UsageLedger, at url: URL, fileManager: FileManager) {
        guard let data = try? JSONEncoder().encode(ledger) else { return }
        try? fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    // MARK: - Enumeration (sync — the enumerator iterator isn't async-safe)

    private struct ScanCandidate {
        let tool: UsageTool
        let url: URL
        let sizeBytes: Int64
        let modified: Date
    }

    private static func enumerateFiles(sources: [TokenUsageScanSource]) -> [ScanCandidate] {
        let fileManager = FileManager.default
        var result: [ScanCandidate] = []
        for source in sources {
            let tool = source.tool
            for root in source.roots {
                guard
                    let enumerator = fileManager.enumerator(
                        at: root,
                        includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
                        options: [.skipsHiddenFiles])
                else { continue }
                for case let url as URL in enumerator where tool.includesFile(url) {
                    guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
                        let size = values.fileSize, size > 0
                    else { continue }
                    result.append(
                        ScanCandidate(
                            tool: tool,
                            url: url,
                            sizeBytes: Int64(size),
                            modified: values.contentModificationDate ?? .distantPast
                        ))
                }
            }
        }
        // OpenCode's SQLite store and its legacy JSON files can hold the same
        // messages; the database wins to avoid double counting.
        if result.contains(where: { $0.tool == .opencode && $0.url.pathExtension == "db" }) {
            result.removeAll { $0.tool == .opencode && $0.url.pathExtension == "json" }
        }
        return result
    }

    // MARK: - Per-file parsing

    private struct ParsedFile {
        var offset: Int64
        var rateLimit: RateLimitSnapshot?
    }

    private static func parseFile(
        url: URL,
        tool: UsageTool,
        from startOffset: Int64,
        fileSize: Int64,
        into days: inout [String: [String: UsageTotals]]
    ) -> ParsedFile? {
        switch tool.strategy(forFile: url) {
        case .incrementalLines:
            return parseIncrementalFile(url: url, tool: tool, from: startOffset, fileSize: fileSize, into: &days)
        case .wholeFile:
            return parseWholeFile(url: url, tool: tool, fileSize: fileSize, into: &days)
        }
    }

    /// Reads `[startOffset, fileSize)` in 4 MB chunks and folds usage events
    /// into `days`. The returned offset excludes a trailing partial line (a
    /// writer mid-append), which is picked up by the next scan.
    private static func parseIncrementalFile(
        url: URL,
        tool: UsageTool,
        from startOffset: Int64,
        fileSize: Int64,
        into days: inout [String: [String: UsageTotals]]
    ) -> ParsedFile? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: UInt64(max(0, startOffset)))
        } catch {
            return nil
        }

        let hints = UsageLineParsing.hints(for: tool)
        var leftover = Data()
        var latestRateLimit: RateLimitSnapshot?
        var currentModel: String?
        var seenDedupeKeys = Set<String>()
        let chunkSize = 4 * 1024 * 1024

        while !Task.isCancelled {
            let chunk: Data
            do {
                chunk = try handle.read(upToCount: chunkSize) ?? Data()
            } catch {
                break
            }
            if chunk.isEmpty { break }
            leftover.append(chunk)

            // Split at the last newline; bytes after it may be a partial line.
            guard let lastNewline = leftover.lastIndex(of: 0x0A) else { continue }
            let complete = leftover[..<lastNewline]
            leftover = Data(leftover[leftover.index(after: lastNewline)...])

            var start = complete.startIndex
            while start < complete.endIndex {
                let end = complete[start...].firstIndex(of: 0x0A) ?? complete.endIndex
                defer { start = end == complete.endIndex ? end : complete.index(after: end) }
                guard end > start else { continue }
                let line = String(decoding: complete[start..<end], as: UTF8.self)

                // Codex records the model on turn_context lines rather than on
                // the token_count events themselves.
                if tool == .codex, line.contains("turn_context"),
                    let model = UsageLineParsing.codexModel(fromLine: line)
                {
                    currentModel = model
                    continue
                }
                guard hints.contains(where: line.contains),
                    var event = UsageLineParsing.event(fromLine: line, tool: tool)
                else { continue }
                if event.model == nil { event.model = currentModel }
                fold(event, rateLimit: &latestRateLimit, seenDedupeKeys: &seenDedupeKeys, into: &days)
            }
        }

        // The consumed offset deliberately excludes `leftover` (unterminated
        // tail), so a partially written line is re-read once complete.
        let offset = fileSize - Int64(leftover.count)
        return ParsedFile(offset: offset, rateLimit: latestRateLimit)
    }

    /// Re-reads a whole-document source (JSON export, snapshot+patch chat
    /// session, SQLite store, cumulative-snapshot log) and replaces its
    /// contribution. Size-capped so a runaway export can't exhaust memory.
    private static func parseWholeFile(
        url: URL,
        tool: UsageTool,
        fileSize: Int64,
        into days: inout [String: [String: UsageTotals]]
    ) -> ParsedFile? {
        guard fileSize <= maximumWholeFileBytes else { return nil }
        let events: [UsageEvent]
        if url.pathExtension == "db" {
            events = openCodeDatabaseEvents(at: url)
        } else {
            guard let data = try? Data(contentsOf: url) else { return nil }
            let text = String(decoding: data, as: UTF8.self)
            switch tool {
            case .cursor:
                events = UsageToolParsers.cursorEvents(fromFileText: text)
            case .opencode:
                guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                    let event = UsageToolParsers.opencodeEvent(from: object)
                else { return ParsedFile(offset: fileSize, rateLimit: nil) }
                events = [event]
            case .kimi:
                events = UsageToolParsers.kimiCLIEvents(fromFileText: text)
            case .copilot:
                events = UsageToolParsers.copilotChatSessionEvents(fromFileText: text)
            default:
                events = []
            }
        }
        var latestRateLimit: RateLimitSnapshot?
        var seenDedupeKeys = Set<String>()
        for event in events {
            if Task.isCancelled { break }
            fold(event, rateLimit: &latestRateLimit, seenDedupeKeys: &seenDedupeKeys, into: &days)
        }
        return ParsedFile(offset: fileSize, rateLimit: latestRateLimit)
    }

    /// Folds one event into the per-day, per-model buckets. Events without a
    /// usable timestamp are dropped rather than polluting a bogus day bucket.
    private static func fold(
        _ event: UsageEvent,
        rateLimit: inout RateLimitSnapshot?,
        seenDedupeKeys: inout Set<String>,
        into days: inout [String: [String: UsageTotals]]
    ) {
        if let key = event.dedupeKey {
            guard seenDedupeKeys.insert(key).inserted else { return }
        }
        if let observed = event.rateLimit,
            observed.capturedAt > rateLimit?.capturedAt ?? .distantPast
        {
            rateLimit = observed
        }
        guard event.timestamp > .distantPast else { return }
        let day = UsageDayKey.make(for: event.timestamp)
        days[day, default: [:]][event.model ?? "", default: UsageTotals()].add(event)
    }

    // MARK: - OpenCode SQLite store

    /// Reads assistant-message JSON out of `opencode*.db` via the system
    /// SQLite. Two schema generations exist: v2 `session_message` (filtered by
    /// `type`) and v1 `message` (filtered by the role inside the JSON).
    private static func openCodeDatabaseEvents(at url: URL) -> [UsageEvent] {
        var database: OpaquePointer?
        guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_close(database) }

        let query: String
        if sqliteTableExists(database, name: "session_message") {
            query = "SELECT data FROM session_message WHERE type = 'assistant'"
        } else if sqliteTableExists(database, name: "message") {
            query = "SELECT data FROM message WHERE json_extract(data, '$.role') = 'assistant'"
        } else {
            return []
        }

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }

        var events: [UsageEvent] = []
        while !Task.isCancelled, sqlite3_step(statement) == SQLITE_ROW {
            guard let text = sqlite3_column_text(statement, 0) else { continue }
            guard let data = String(cString: text).data(using: .utf8),
                let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let event = UsageToolParsers.opencodeEvent(from: object)
            else { continue }
            events.append(event)
        }
        return events
    }

    private static func sqliteTableExists(_ database: OpaquePointer?, name: String) -> Bool {
        var statement: OpaquePointer?
        guard
            sqlite3_prepare_v2(
                database, "SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?1", -1, &statement, nil
            ) == SQLITE_OK
        else { return false }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, (name as NSString).utf8String, -1, nil)
        return sqlite3_step(statement) == SQLITE_ROW
    }
}
