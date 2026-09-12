import Foundation

/// A local AI coding tool whose token usage is recovered from on-disk logs.
/// All parsing is read-only and offline; `doubao` has no local log source and
/// is listed so the UI can explain why it is absent.
enum UsageTool: String, CaseIterable, Codable, Identifiable, Sendable {
    case claude
    case codex
    case kimi
    case grok
    case cursor
    case copilot
    case antigravity
    case opencode
    case glm
    case doubao

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .claude: "Claude Code"
        case .codex: "Codex"
        case .kimi: "Kimi Code"
        case .grok: "Grok"
        case .cursor: "Cursor"
        case .copilot: "GitHub Copilot"
        case .antigravity: "Antigravity"
        case .opencode: "OpenCode"
        case .glm: "GLM / ZCode"
        case .doubao: "Doubao"
        }
    }

    /// Roots scanned for usage logs. Empty for tools with no local source.
    var scanRoots: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        switch self {
        case .claude:
            return [home.appendingPathComponent(".claude/projects")]
        case .codex:
            return [
                home.appendingPathComponent(".codex/sessions"),
                home.appendingPathComponent(".codex/archived_sessions"),
            ]
        case .kimi:
            // kimi-code (incremental usage.record lines) and the legacy Kimi
            // CLI (StatusUpdate snapshots) share the wire.jsonl name but need
            // different scan strategies — see `strategy(forFile:)`.
            return [
                home.appendingPathComponent(".kimi-code/sessions"),
                home.appendingPathComponent(".kimi/sessions"),
            ]
        case .grok:
            return [home.appendingPathComponent(".grok/logs")]
        case .cursor:
            // Cursor keeps no parseable local token detail; this cache is
            // written by `tokscale cursor sync` from Cursor's dashboard API.
            return [home.appendingPathComponent(".config/tokscale/cursor-cache")]
        case .copilot:
            return [
                home.appendingPathComponent(".copilot/otel"),
                home.appendingPathComponent("Library/Application Support/Code/User/workspaceStorage"),
            ]
        case .antigravity:
            // The IDE's sessions live behind a language-server RPC; this cache
            // is written by `tokscale antigravity sync`.
            return [home.appendingPathComponent(".config/tokscale/antigravity-cache")]
        case .opencode:
            return [home.appendingPathComponent(".local/share/opencode")]
        case .glm:
            return [home.appendingPathComponent(".zcode/projects")]
        case .doubao:
            return []
        }
    }

    /// Which enumerated files can carry usage records for this tool.
    func includesFile(_ url: URL) -> Bool {
        switch self {
        case .claude, .codex, .glm:
            return url.pathExtension == "jsonl"
        case .kimi:
            return url.lastPathComponent == "wire.jsonl"
        case .grok:
            return url.lastPathComponent == "unified.jsonl"
        case .cursor:
            return url.pathExtension == "json" && url.lastPathComponent.hasPrefix("usage")
        case .copilot:
            let path = url.path
            return url.pathExtension == "jsonl"
                && (path.contains("/.copilot/otel/") || path.contains("/chatSessions/"))
        case .antigravity:
            return url.pathExtension == "jsonl"
        case .opencode:
            if url.pathExtension == "json" { return url.path.contains("/storage/message/") }
            return url.pathExtension == "db" && url.deletingPathExtension().lastPathComponent.hasPrefix("opencode")
        case .doubao:
            return false
        }
    }
}

/// How a log file is read: append-only JSONL is read incrementally from the
/// last consumed offset; everything else (whole-document JSON, snapshot-patch
/// chat sessions, SQLite, cumulative-snapshot logs) is re-read whole and its
/// ledger contribution replaced.
enum UsageScanStrategy: Equatable, Sendable {
    case incrementalLines
    case wholeFile
}

extension UsageTool {
    func strategy(forFile url: URL) -> UsageScanStrategy {
        switch self {
        case .claude, .codex, .grok, .glm, .antigravity:
            return .incrementalLines
        case .kimi:
            return url.path.contains("/.kimi-code/") ? .incrementalLines : .wholeFile
        case .copilot:
            return url.path.contains("/.copilot/otel/") ? .incrementalLines : .wholeFile
        case .cursor, .opencode:
            return .wholeFile
        case .doubao:
            return .wholeFile
        }
    }
}

/// One request/turn's token delta extracted from a log line (never cumulative).
struct UsageEvent: Equatable, Sendable {
    let tool: UsageTool
    let timestamp: Date
    /// Codex attaches the model to turn_context lines, so the scanner fills it
    /// in after the event is parsed.
    var model: String?
    var input: Int64 = 0
    var output: Int64 = 0
    var cacheRead: Int64 = 0
    var cacheWrite: Int64 = 0
    var reasoning: Int64 = 0

    var rateLimit: RateLimitSnapshot?
    /// Optional per-request id used to drop duplicate usage records within one
    /// parse pass (Copilot OTel spans, Antigravity responses).
    var dedupeKey: String? = nil
}

/// Provider rate-limit window observed in local logs (Codex writes these into
/// its session files, so no network call is needed).
struct RateLimitSnapshot: Codable, Equatable, Sendable {
    var usedPercent: Double
    var windowMinutes: Int?
    var resetsAt: Date?
    var planType: String?
    var capturedAt: Date
}

/// Accumulated token counts for one bucket (a model within a day, a tool, …).
struct UsageTotals: Codable, Equatable, Sendable {
    var input: Int64 = 0
    var output: Int64 = 0
    var cacheRead: Int64 = 0
    var cacheWrite: Int64 = 0
    var reasoning: Int64 = 0

    var total: Int64 { input + output + cacheRead + cacheWrite + reasoning }

    /// cacheRead / (all input-side tokens); nil when there was no input at all.
    var cacheHitRate: Double? {
        let inputSide = input + cacheRead + cacheWrite
        guard inputSide > 0 else { return nil }
        return Double(cacheRead) / Double(inputSide)
    }

    mutating func add(_ event: UsageEvent) {
        input += event.input
        output += event.output
        cacheRead += event.cacheRead
        cacheWrite += event.cacheWrite
        reasoning += event.reasoning
    }

    mutating func add(_ other: UsageTotals) {
        input += other.input
        output += other.output
        cacheRead += other.cacheRead
        cacheWrite += other.cacheWrite
        reasoning += other.reasoning
    }
}

/// One scanned file's persisted contribution: the byte offset already consumed
/// plus per-day, per-model token totals. JSONL logs are append-only, so a
/// refresh only reads from `offset` onwards; a file that shrank or was
/// rewritten is rescanned from zero and its contribution replaced (never
/// double-counted). Contributions of deleted files are kept so history
/// survives each tool's own retention cleanup.
struct UsageFileContribution: Codable, Equatable, Sendable {
    var offset: Int64
    var modified: Date
    var days: [String: [String: UsageTotals]] = [:]  // "yyyy-MM-dd" → model ("" = unknown) → totals
}

/// The whole persisted usage ledger (`usage-ledger.json` under Application
/// Support), written atomically after each scan.
struct UsageLedger: Codable, Equatable, Sendable {
    static let currentVersion = 1

    var version = UsageLedger.currentVersion
    /// Key: "<tool rawValue>:<standardized path>" (see `UsageFileKey`).
    var files: [String: UsageFileContribution] = [:]
    /// Latest observed provider rate-limit snapshot per tool rawValue.
    var rateLimits: [String: RateLimitSnapshot] = [:]

    /// Drops day buckets older than `retentionDays` (string compare works on
    /// zero-padded yyyy-MM-dd keys).
    mutating func prune(olderThan cutoffDay: String) {
        for key in files.keys {
            guard var entry = files[key] else { continue }
            entry.days = entry.days.filter { $0.key >= cutoffDay }
            files[key] = entry
        }
    }
}

enum UsageFileKey {
    static func make(tool: UsageTool, url: URL) -> String {
        "\(tool.rawValue):\(url.standardizedFileURL.path)"
    }

    static func tool(of key: String) -> UsageTool? {
        guard let raw = key.split(separator: ":", maxSplits: 1).first else { return nil }
        return UsageTool(rawValue: String(raw))
    }

    static func path(of key: String) -> String {
        guard let index = key.firstIndex(of: ":") else { return key }
        return String(key[key.index(after: index)...])
    }
}

/// Local-timezone day keys; the lexicographically sortable "yyyy-MM-dd" format
/// doubles as the ledger's storage key.
enum UsageDayKey {
    static func make(for date: Date) -> String {
        formatter.string(from: date)
    }

    static func offset(_ days: Int, from date: Date = Date()) -> String {
        let shifted = Calendar.current.date(byAdding: .day, value: days, to: date) ?? date
        return formatter.string(from: shifted)
    }

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()
}

/// Pure per-line parsers, one per tool schema. Callers pre-filter lines with
/// `hints` substrings so full JSON parsing only runs on candidate lines.
enum UsageLineParsing {
    /// Cheap substrings, one of which must be present for the tool's
    /// usage/quota lines; used to skip JSON parsing for the vast majority of
    /// log lines.
    static func hints(for tool: UsageTool) -> [String] {
        switch tool {
        case .claude: return ["\"usage\""]
        case .codex: return ["token_count"]
        case .kimi: return ["\"usage.record\""]
        case .grok: return ["inference_done", "credits config"]
        case .glm: return ["usage"]
        case .copilot: return ["gen_ai.usage"]
        case .antigravity: return ["\"usage\""]
        case .cursor, .opencode, .doubao: return ["\u{1}"]  // whole-file parsing or no local source
        }
    }

    static func event(fromLine line: String, tool: UsageTool) -> UsageEvent? {
        guard hints(for: tool).contains(where: line.contains) else { return nil }
        guard let data = line.data(using: .utf8),
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        switch tool {
        case .claude: return claudeEvent(from: obj)
        case .codex: return codexEvent(from: obj)
        case .kimi: return kimiEvent(from: obj)
        case .grok: return grokEvent(from: obj)
        case .glm: return UsageToolParsers.zcodeEvent(from: obj)
        case .copilot: return UsageToolParsers.copilotOTelEvent(from: obj)
        case .antigravity: return UsageToolParsers.antigravityEvent(from: obj)
        case .cursor, .opencode, .doubao:
            return nil
        }
    }

    // MARK: - Claude Code

    /// Claude assistant turns: top-level `type == "assistant"`, token counts in
    /// `message.usage`, model in `message.model`, ISO8601 `timestamp`.
    static func claudeEvent(from obj: [String: Any]) -> UsageEvent? {
        guard obj["type"] as? String == "assistant",
            let message = obj["message"] as? [String: Any],
            let usage = message["usage"] as? [String: Any]
        else { return nil }
        var event = UsageEvent(
            tool: .claude,
            timestamp: isoDate(obj["timestamp"] as? String) ?? .distantPast,
            model: message["model"] as? String
        )
        event.input = int64(usage["input_tokens"])
        event.output = int64(usage["output_tokens"])
        event.cacheRead = int64(usage["cache_read_input_tokens"])
        event.cacheWrite = int64(usage["cache_creation_input_tokens"])
        return event
    }

    // MARK: - Codex

    /// Codex `token_count` events: `info.last_token_usage` is the per-turn
    /// delta (`total_token_usage` is cumulative and must not be summed). The
    /// same line carries the account's `rate_limits` windows.
    static func codexEvent(from obj: [String: Any]) -> UsageEvent? {
        guard obj["type"] as? String == "event_msg",
            let payload = obj["payload"] as? [String: Any],
            payload["type"] as? String == "token_count",
            let info = payload["info"] as? [String: Any]
        else { return nil }
        let timestamp = isoDate(obj["timestamp"] as? String) ?? .distantPast
        var event = UsageEvent(tool: .codex, timestamp: timestamp, model: nil)
        if let last = info["last_token_usage"] as? [String: Any] {
            event.input = int64(last["input_tokens"])
            event.output = int64(last["output_tokens"])
            event.cacheRead = int64(last["cached_input_tokens"])
            event.cacheWrite = int64(last["cache_write_input_tokens"])
            event.reasoning = int64(last["reasoning_output_tokens"])
        }
        event.rateLimit = codexRateLimit(from: payload["rate_limits"] as? [String: Any], capturedAt: timestamp)
        return event
    }

    /// Codex carries the model on `turn_context` lines, not on token_count;
    /// the scanner tracks it while streaming a file.
    static func codexModel(fromLine line: String) -> String? {
        guard line.contains("turn_context"),
            let data = line.data(using: .utf8),
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            obj["type"] as? String == "turn_context",
            let payload = obj["payload"] as? [String: Any]
        else { return nil }
        return payload["model"] as? String
    }

    private static func codexRateLimit(from limits: [String: Any]?, capturedAt: Date) -> RateLimitSnapshot? {
        guard let limits, let primary = limits["primary"] as? [String: Any],
            let used = primary["used_percent"] as? Double
        else { return nil }
        var snapshot = RateLimitSnapshot(usedPercent: used, capturedAt: capturedAt)
        snapshot.windowMinutes = primary["window_minutes"] as? Int
        if let resetsAt = primary["resets_at"] as? TimeInterval {
            snapshot.resetsAt = Date(timeIntervalSince1970: resetsAt)
        }
        snapshot.planType = limits["plan_type"] as? String
        return snapshot
    }

    // MARK: - Kimi Code

    /// Kimi Code wire logs: `usage.record` with per-turn `usageScope` deltas.
    /// Only `usageScope == "turn"` counts — "session" records are bookkeeping
    /// (compaction etc.) and `step.end` lines duplicate the same usage.
    /// `time` is epoch milliseconds.
    static func kimiEvent(from obj: [String: Any]) -> UsageEvent? {
        guard obj["type"] as? String == "usage.record",
            obj["usageScope"] as? String == "turn",
            let usage = obj["usage"] as? [String: Any]
        else { return nil }
        var timestamp = Date.distantPast
        if let time = obj["time"] as? TimeInterval {
            timestamp = Date(timeIntervalSince1970: time / 1000)
        }
        var event = UsageEvent(tool: .kimi, timestamp: timestamp, model: obj["model"] as? String)
        event.input = int64(usage["inputOther"])
        event.output = int64(usage["output"])
        event.cacheRead = int64(usage["inputCacheRead"])
        event.cacheWrite = int64(usage["inputCacheCreation"])
        return event
    }

    // MARK: - Grok

    /// Grok CLI unified log: one `shell.turn.inference_done` line per request.
    /// The context has no model id, so Grok usage aggregates at tool level.
    /// `billing: fetched credits config` lines carry the account's credit
    /// quota, which surfaces as a rate-limit snapshot (tokens stay zero and
    /// the timestamp is left at distantPast so the line creates no day bucket).
    static func grokEvent(from obj: [String: Any]) -> UsageEvent? {
        guard let msg = obj["msg"] as? String else { return nil }
        if msg == "billing: fetched credits config" {
            guard let rateLimit = grokBillingRateLimit(from: obj) else { return nil }
            var event = UsageEvent(tool: .grok, timestamp: .distantPast, model: nil)
            event.rateLimit = rateLimit
            return event
        }
        guard msg == "shell.turn.inference_done",
            let context = obj["ctx"] as? [String: Any]
        else { return nil }
        var event = UsageEvent(
            tool: .grok,
            timestamp: isoDate(obj["ts"] as? String) ?? .distantPast,
            model: nil
        )
        event.input = int64(context["prompt_tokens"])
        event.output = int64(context["completion_tokens"])
        event.cacheRead = int64(context["cached_prompt_tokens"])
        event.reasoning = int64(context["reasoning_tokens"])
        return event
    }

    /// `billing: fetched credits config` → quota snapshot: credit usage
    /// percent, billing period end as the reset time, subscription tier as the
    /// plan. The window length is derived from the period start/end.
    private static func grokBillingRateLimit(from obj: [String: Any]) -> RateLimitSnapshot? {
        guard let ctx = obj["ctx"] as? [String: Any],
            let config = ctx["config"] as? [String: Any],
            let used = config["creditUsagePercent"] as? Double
        else { return nil }
        var snapshot = RateLimitSnapshot(
            usedPercent: used,
            capturedAt: isoDate(obj["ts"] as? String) ?? Date()
        )
        if let period = config["currentPeriod"] as? [String: Any] {
            let start = isoDate(period["start"] as? String)
            let end = isoDate(period["end"] as? String)
            if let start, let end, end > start {
                snapshot.windowMinutes = Int((end.timeIntervalSince(start) / 60).rounded())
            }
            snapshot.resetsAt = end
        }
        snapshot.planType = ctx["subscriptionTier"] as? String
        return snapshot
    }

    // MARK: - Shared helpers

    static func int64(_ value: Any?) -> Int64 {
        switch value {
        case let number as Int64: return number
        case let number as Int: return Int64(number)
        case let number as Double: return Int64(number)
        case let string as String: return Int64(string) ?? Int64(Double(string) ?? 0)
        case let number as NSNumber: return number.int64Value
        default: return 0
        }
    }

    static func isoDate(_ string: String?) -> Date? {
        guard let string else { return nil }
        return iso8601Fractional.date(from: string) ?? iso8601.date(from: string)
    }

    /// Epoch-milliseconds timestamps appear as numbers or numeric strings
    /// (Cursor writes them as strings; OpenCode sometimes as floats).
    static func epochMillis(_ value: Any?) -> Date? {
        switch value {
        case let string as String:
            return Double(string).map { Date(timeIntervalSince1970: $0 / 1000) }
        case let number as NSNumber:
            return Date(timeIntervalSince1970: number.doubleValue / 1000)
        default:
            return nil
        }
    }

    // ISO8601DateFormatter isn't Sendable; these are configured once and only
    // ever used to parse (formatters are reentrant for reads), so the unsafe
    // opt-out is safe here.
    nonisolated(unsafe) private static let iso8601Fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    nonisolated(unsafe) private static let iso8601: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}

/// Built-in price list (USD per 1M tokens, matched by longest model-name
/// substring). Static and offline by design — figures go stale over time, so
/// every cost figure in the UI is labelled as an estimate.
enum ModelPricing {
    struct Pricing: Equatable, Sendable {
        var inputPerMillion: Double
        var outputPerMillion: Double
        var cacheReadPerMillion: Double
        var cacheWritePerMillion: Double
    }

    static let table: [(match: String, pricing: Pricing)] = [
        (
            "claude-opus-4",
            Pricing(inputPerMillion: 15, outputPerMillion: 75, cacheReadPerMillion: 1.5, cacheWritePerMillion: 18.75)
        ),
        (
            "claude-sonnet-4",
            Pricing(inputPerMillion: 3, outputPerMillion: 15, cacheReadPerMillion: 0.3, cacheWritePerMillion: 3.75)
        ),
        (
            "claude-haiku",
            Pricing(inputPerMillion: 1, outputPerMillion: 5, cacheReadPerMillion: 0.1, cacheWritePerMillion: 1.25)
        ),
        (
            "gpt-5",
            Pricing(inputPerMillion: 1.25, outputPerMillion: 10, cacheReadPerMillion: 0.125, cacheWritePerMillion: 1.25)
        ),
        (
            "kimi",
            Pricing(inputPerMillion: 0.6, outputPerMillion: 2.5, cacheReadPerMillion: 0.15, cacheWritePerMillion: 0.6)
        ),
        ("grok", Pricing(inputPerMillion: 3, outputPerMillion: 15, cacheReadPerMillion: 0.75, cacheWritePerMillion: 3)),
    ]

    static func pricing(forModel model: String) -> Pricing? {
        let lowered = model.lowercased()
        return table.first { lowered.contains($0.match) }?.pricing
    }

    /// Estimated USD cost; nil when the model isn't in the price table.
    static func cost(of totals: UsageTotals, model: String) -> Double? {
        guard let pricing = pricing(forModel: model) else { return nil }
        return
            (Double(totals.input) * pricing.inputPerMillion
            + Double(totals.output + totals.reasoning) * pricing.outputPerMillion
            + Double(totals.cacheRead) * pricing.cacheReadPerMillion
            + Double(totals.cacheWrite) * pricing.cacheWritePerMillion) / 1_000_000
    }
}

/// Pure aggregation over the persisted ledger; the view layer never touches
/// the raw per-file structure.
enum UsageAggregation {
    /// Sums contributions whose day key is `>= sinceDay` (nil = all time).
    static func totals(files: [String: UsageFileContribution], sinceDay: String? = nil) -> UsageTotals {
        var result = UsageTotals()
        for entry in files.values {
            for (day, models) in entry.days where sinceDay == nil || day >= sinceDay! {
                for totals in models.values { result.add(totals) }
            }
        }
        return result
    }

    static func totalsByTool(
        files: [String: UsageFileContribution],
        sinceDay: String? = nil
    ) -> [UsageTool: UsageTotals] {
        var result: [UsageTool: UsageTotals] = [:]
        for (key, entry) in files {
            guard let tool = UsageFileKey.tool(of: key) else { continue }
            for (day, models) in entry.days where sinceDay == nil || day >= sinceDay! {
                for totals in models.values {
                    result[tool, default: UsageTotals()].add(totals)
                }
            }
        }
        return result
    }

    /// Model breakdown for one tool ("" key = unknown model).
    static func totalsByModel(
        files: [String: UsageFileContribution],
        tool: UsageTool,
        sinceDay: String? = nil
    ) -> [String: UsageTotals] {
        var result: [String: UsageTotals] = [:]
        for (key, entry) in files where UsageFileKey.tool(of: key) == tool {
            for (day, models) in entry.days where sinceDay == nil || day >= sinceDay! {
                for (model, totals) in models {
                    result[model, default: UsageTotals()].add(totals)
                }
            }
        }
        return result
    }

    /// Per-day totals for the last `days` days including today, oldest first.
    static func dailySeries(
        files: [String: UsageFileContribution],
        days: Int,
        from now: Date = Date()
    ) -> [(day: String, totals: UsageTotals)] {
        let firstDay = UsageDayKey.offset(-(days - 1), from: now)
        let today = UsageDayKey.make(for: now)
        var byDay: [String: UsageTotals] = [:]
        for entry in files.values {
            for (day, models) in entry.days where day >= firstDay && day <= today {
                for totals in models.values {
                    byDay[day, default: UsageTotals()].add(totals)
                }
            }
        }
        var series: [(String, UsageTotals)] = []
        var offset = days - 1
        while offset >= 0 {
            let day = UsageDayKey.offset(-offset, from: now)
            series.append((day, byDay[day] ?? UsageTotals()))
            offset -= 1
        }
        return series
    }

    /// Per-day, per-tool totals for the last `days` days including today,
    /// oldest first — the stacked bar chart's data source.
    static func dailySeriesByTool(
        files: [String: UsageFileContribution],
        days: Int,
        from now: Date = Date()
    ) -> [(day: String, byTool: [UsageTool: UsageTotals])] {
        let firstDay = UsageDayKey.offset(-(days - 1), from: now)
        let today = UsageDayKey.make(for: now)
        var byDay: [String: [UsageTool: UsageTotals]] = [:]
        for (key, entry) in files {
            guard let tool = UsageFileKey.tool(of: key) else { continue }
            for (day, models) in entry.days where day >= firstDay && day <= today {
                for totals in models.values {
                    byDay[day, default: [:]][tool, default: UsageTotals()].add(totals)
                }
            }
        }
        var series: [(String, [UsageTool: UsageTotals])] = []
        var offset = days - 1
        while offset >= 0 {
            let day = UsageDayKey.offset(-offset, from: now)
            series.append((day, byDay[day] ?? [:]))
            offset -= 1
        }
        return series
    }

    /// Heaviest session files (by total tokens) since `sinceDay`, newest
    /// activity not considered — pure token ranking.
    static func topFiles(
        files: [String: UsageFileContribution],
        sinceDay: String? = nil,
        limit: Int = 10
    ) -> [(key: String, tool: UsageTool, totals: UsageTotals)] {
        var rows: [(String, UsageTool, UsageTotals)] = []
        for (key, entry) in files {
            guard let tool = UsageFileKey.tool(of: key) else { continue }
            var totals = UsageTotals()
            for (day, models) in entry.days where sinceDay == nil || day >= sinceDay! {
                for modelTotals in models.values { totals.add(modelTotals) }
            }
            if totals.total > 0 { rows.append((key, tool, totals)) }
        }
        return rows.sorted { $0.2.total > $1.2.total }
            .prefix(limit)
            .map { (key: $0.0, tool: $0.1, totals: $0.2) }
    }

    /// Estimated cost of a model breakdown. `complete` is false when any
    /// non-zero bucket has no price (unknown model), so the UI can flag it.
    static func costUSD(modelTotals: [String: UsageTotals]) -> (value: Double, complete: Bool) {
        var value = 0.0
        var complete = true
        for (model, totals) in modelTotals where totals.total > 0 {
            if let cost = ModelPricing.cost(of: totals, model: model) {
                value += cost
            } else {
                complete = false
            }
        }
        return (value, complete)
    }

    /// Model breakdown across every tool (used for whole-period cost).
    static func totalsByModel(
        files: [String: UsageFileContribution],
        sinceDay: String? = nil
    ) -> [String: UsageTotals] {
        var result: [String: UsageTotals] = [:]
        for (key, entry) in files {
            guard let tool = UsageFileKey.tool(of: key) else { continue }
            for (day, models) in entry.days where sinceDay == nil || day >= sinceDay! {
                for (model, totals) in models {
                    // Unknown-model buckets stay per-tool so a Grok total can
                    // still price against the tool's generic pricing entry.
                    let resolvedModel = model.isEmpty ? tool.rawValue : model
                    result[resolvedModel, default: UsageTotals()].add(totals)
                }
            }
        }
        return result
    }
}
