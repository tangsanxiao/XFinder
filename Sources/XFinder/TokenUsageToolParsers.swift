import Foundation

/// Parsers for the tools that aren't plain append-only usage lines:
/// whole-document JSON (Cursor's tokscale cache, OpenCode messages),
/// snapshot+patch chat sessions (VS Code Copilot), cumulative status
/// snapshots (legacy Kimi CLI), and the line schemas of GLM/ZCode, Copilot
/// OTel, and the Antigravity tokscale cache. Field names follow tokscale's
/// documented parser behaviour; all functions are pure and unit-tested.
enum UsageToolParsers {
    // MARK: - GLM / ZCode (line)

    /// ZCode JSONL is Claude-like but with inclusive counts: `input_tokens`
    /// already contains the cache buckets and `output_tokens` already contains
    /// reasoning — normalize into non-overlapping buckets. Field aliases cover
    /// the schema variants seen across versions.
    static func zcodeEvent(from obj: [String: Any]) -> UsageEvent? {
        guard obj["role"] as? String == "assistant" || obj["type"] as? String == "assistant" else { return nil }
        guard let usage = (obj["usage"] ?? obj["token_usage"]) as? [String: Any] else { return nil }
        let rawInput = firstInt(usage, ["input_tokens", "prompt_tokens", "inputTokens"])
        let rawOutput = firstInt(usage, ["output_tokens", "completion_tokens", "outputTokens"])
        let cacheRead = firstInt(usage, ["input_cache_read", "cache_read_tokens", "cacheReadTokens"])
        let cacheWrite = firstInt(usage, ["input_cache_creation", "cache_write_tokens", "cacheCreationTokens"])
        let reasoning = firstInt(usage, ["reasoning_tokens", "reasoning", "reasoningTokens"])
        var event = UsageEvent(
            tool: .glm,
            timestamp: UsageLineParsing.isoDate(obj["timestamp"] as? String) ?? .distantPast,
            model: obj["model"] as? String
        )
        event.input = max(0, rawInput - cacheRead - cacheWrite)
        event.output = max(0, rawOutput - reasoning)
        event.cacheRead = cacheRead
        event.cacheWrite = cacheWrite
        event.reasoning = reasoning
        return event
    }

    // MARK: - Copilot OTel (line)

    /// Copilot CLI's OTel file exporter (`~/.copilot/otel/*.jsonl`, opt-in via
    /// COPILOT_OTEL_* env vars). Usage lives in `gen_ai.usage.*` attributes;
    /// spans and inference logs of one request carry the same
    /// `gen_ai.response.id`, which the scanner uses to drop duplicates.
    static func copilotOTelEvent(from obj: [String: Any]) -> UsageEvent? {
        guard let attributes = obj["attributes"] as? [String: Any] else { return nil }
        let input = UsageLineParsing.int64(attributes["gen_ai.usage.input_tokens"])
        let output = UsageLineParsing.int64(attributes["gen_ai.usage.output_tokens"])
        guard input > 0 || output > 0 else { return nil }
        var timestamp = Date.distantPast
        if let start = obj["startTime"] as? [Any], let seconds = start.first {
            let nanos = start.count > 1 ? UsageLineParsing.int64(start[1]) : 0
            timestamp = Date(
                timeIntervalSince1970: Double(UsageLineParsing.int64(seconds)) + Double(nanos) / 1_000_000_000)
        }
        var event = UsageEvent(
            tool: .copilot,
            timestamp: timestamp,
            model: (attributes["gen_ai.response.model"] ?? attributes["gen_ai.request.model"]) as? String
        )
        event.input = input
        event.output = output
        event.cacheRead = firstInt(
            attributes,
            ["gen_ai.usage.cache_read.input_tokens", "gen_ai.usage.cache_read_input_tokens"])
        event.cacheWrite = firstInt(
            attributes,
            [
                "gen_ai.usage.cache_write.input_tokens", "gen_ai.usage.cache_creation.input_tokens",
                "gen_ai.usage.cache_creation_input_tokens",
            ])
        event.reasoning = firstInt(
            attributes,
            ["gen_ai.usage.reasoning.output_tokens", "gen_ai.usage.reasoning_tokens"])
        event.dedupeKey = (attributes["gen_ai.response.id"] as? String) ?? (obj["spanId"] as? String)
        return event
    }

    // MARK: - Antigravity tokscale cache (line)

    /// `~/.config/tokscale/antigravity-cache/sessions/*.jsonl` written by
    /// `tokscale antigravity sync` (the IDE itself only exposes sessions via
    /// its language-server RPC). `timestamp` is epoch milliseconds.
    static func antigravityEvent(from obj: [String: Any]) -> UsageEvent? {
        guard obj["type"] as? String == "usage" else { return nil }
        var event = UsageEvent(
            tool: .antigravity,
            timestamp: UsageLineParsing.epochMillis(obj["timestamp"]) ?? .distantPast,
            model: obj["modelId"] as? String
        )
        event.input = UsageLineParsing.int64(obj["input"])
        event.output = UsageLineParsing.int64(obj["output"])
        event.cacheRead = UsageLineParsing.int64(obj["cacheRead"])
        event.cacheWrite = UsageLineParsing.int64(obj["cacheWrite"])
        event.reasoning = UsageLineParsing.int64(obj["reasoning"])
        event.dedupeKey = obj["responseId"] as? String
        return event
    }

    // MARK: - Cursor tokscale cache (whole JSON document)

    /// `~/.config/tokscale/cursor-cache/usage*.json` written by
    /// `tokscale cursor sync` from Cursor's dashboard API (Cursor keeps no
    /// parseable local token detail itself). One event per model request.
    static func cursorEvents(fromFileText text: String) -> [UsageEvent] {
        guard let data = text.data(using: .utf8),
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let events = obj["usageEventsDisplay"] as? [[String: Any]]
        else { return [] }
        return events.compactMap { entry in
            guard let tokenUsage = entry["tokenUsage"] as? [String: Any] else { return nil }
            var event = UsageEvent(
                tool: .cursor,
                timestamp: UsageLineParsing.epochMillis(entry["timestamp"]) ?? .distantPast,
                model: entry["model"] as? String
            )
            event.input = UsageLineParsing.int64(tokenUsage["inputTokens"])
            event.output = UsageLineParsing.int64(tokenUsage["outputTokens"])
            event.cacheRead = UsageLineParsing.int64(tokenUsage["cacheReadTokens"])
            event.cacheWrite = UsageLineParsing.int64(tokenUsage["cacheWriteTokens"])
            return event
        }
    }

    // MARK: - OpenCode (message JSON, shared by storage files and SQLite rows)

    /// One OpenCode assistant message (`storage/message/**.json`, or the `data`
    /// column of the opencode.db message tables). v1 rows carry a top-level
    /// `role`; v2 rows nest the model under `model{id,providerID}`.
    static func opencodeEvent(from obj: [String: Any]) -> UsageEvent? {
        if let role = obj["role"] as? String, role != "assistant" { return nil }
        guard let tokens = obj["tokens"] as? [String: Any] else { return nil }
        let cache = tokens["cache"] as? [String: Any]
        var event = UsageEvent(
            tool: .opencode,
            timestamp: UsageLineParsing.epochMillis((obj["time"] as? [String: Any])?["created"]) ?? .distantPast,
            model: ((obj["model"] as? [String: Any])?["id"] as? String) ?? (obj["modelID"] as? String)
        )
        event.input = UsageLineParsing.int64(tokens["input"])
        event.output = UsageLineParsing.int64(tokens["output"])
        event.reasoning = UsageLineParsing.int64(tokens["reasoning"])
        event.cacheRead = UsageLineParsing.int64(cache?["read"])
        event.cacheWrite = UsageLineParsing.int64(cache?["write"])
        event.dedupeKey = obj["id"] as? String
        return event
    }

    // MARK: - Legacy Kimi CLI (whole file: cumulative snapshots)

    /// `~/.kimi/sessions/**/wire.jsonl`: StatusUpdate lines stream a
    /// *cumulative* `token_usage` snapshot per `message_id`, so only the latest
    /// snapshot per message counts. `timestamp` is epoch seconds (float).
    static func kimiCLIEvents(fromFileText text: String) -> [UsageEvent] {
        var latestByMessage: [String: UsageEvent] = [:]
        var anonymousIndex = 0
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard line.contains("StatusUpdate"),
                let data = line.data(using: .utf8),
                let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let message = obj["message"] as? [String: Any],
                message["type"] as? String == "StatusUpdate",
                let payload = message["payload"] as? [String: Any],
                let usage = payload["token_usage"] as? [String: Any]
            else { continue }
            var timestamp = Date.distantPast
            if let seconds = (obj["timestamp"] as? Double) ?? (obj["timestamp"] as? Int).map(Double.init) {
                timestamp = Date(timeIntervalSince1970: seconds)
            }
            var event = UsageEvent(tool: .kimi, timestamp: timestamp, model: nil)
            event.input = UsageLineParsing.int64(usage["input_other"])
            event.output = UsageLineParsing.int64(usage["output"])
            event.cacheRead = UsageLineParsing.int64(usage["input_cache_read"])
            event.cacheWrite = UsageLineParsing.int64(usage["input_cache_creation"])
            let key = (payload["message_id"] as? String) ?? "anonymous-\(anonymousIndex)"
            anonymousIndex += 1
            latestByMessage[key] = event
        }
        return Array(latestByMessage.values)
    }

    // MARK: - VS Code Copilot chat sessions (whole file: snapshot + patches)

    /// `workspaceStorage/*/chatSessions/*.jsonl` is a snapshot-and-patch log:
    /// `kind:0` replaces the document, `kind:1` sets a value at a key path,
    /// `kind:2` appends to an array. Replaying it yields the final `requests`
    /// array; only Copilot's own requests carry token fields.
    static func copilotChatSessionEvents(fromFileText text: String) -> [UsageEvent] {
        var requests: [[String: Any]] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard line.contains("\"kind\""),
                let data = line.data(using: .utf8),
                let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let kind = obj["kind"] as? Int
            else { continue }
            switch kind {
            case 0:
                if let document = obj["v"] as? [String: Any],
                    let snapshot = document["requests"] as? [[String: Any]]
                {
                    requests = snapshot
                }
            case 1:
                guard let keyPath = obj["k"] as? [Any], keyPath.first as? String == "requests" else { continue }
                if keyPath.count == 1, let value = obj["v"] as? [[String: Any]] {
                    requests = value
                } else if keyPath.count == 3, let index = keyPath[1] as? Int,
                    requests.indices.contains(index), let field = keyPath[2] as? String, let value = obj["v"]
                {
                    requests[index][field] = value
                }
            case 2:
                guard let keyPath = obj["k"] as? [Any], keyPath.first as? String == "requests",
                    let appended = obj["v"] as? [[String: Any]]
                else { continue }
                requests.append(contentsOf: appended)
            default:
                continue
            }
        }
        return requests.compactMap(copilotChatRequestEvent(from:))
    }

    private static func copilotChatRequestEvent(from request: [String: Any]) -> UsageEvent? {
        let modelID = request["modelId"] as? String
        let metadata = (request["result"] as? [String: Any])?["metadata"] as? [String: Any]
        let resolvedModel = metadata?["resolvedModel"] as? String
        // Other extensions can write requests into the same session; only
        // Copilot's carry a copilot/ model id or a resolved model.
        guard modelID?.hasPrefix("copilot/") == true || resolvedModel != nil else { return nil }
        var input = UsageLineParsing.int64(request["promptTokens"])
        if input == 0 { input = UsageLineParsing.int64(metadata?["promptTokens"]) }
        var output = UsageLineParsing.int64(request["completionTokens"])
        if output == 0 { output = UsageLineParsing.int64(metadata?["outputTokens"]) }
        var reasoning: Int64 = 0
        for round in metadata?["toolCallRounds"] as? [[String: Any]] ?? [] {
            reasoning += UsageLineParsing.int64((round["thinking"] as? [String: Any])?["tokens"])
        }
        guard input > 0 || output > 0 else { return nil }
        var event = UsageEvent(
            tool: .copilot,
            timestamp: UsageLineParsing.epochMillis(request["timestamp"]) ?? .distantPast,
            model: resolvedModel ?? modelID?.replacingOccurrences(of: "copilot/", with: "")
        )
        event.input = input
        event.output = output
        event.reasoning = reasoning
        event.dedupeKey = request["requestId"] as? String
        return event
    }

    // MARK: - Helpers

    private static func firstInt(_ dictionary: [String: Any], _ keys: [String]) -> Int64 {
        for key in keys where dictionary[key] != nil {
            return UsageLineParsing.int64(dictionary[key])
        }
        return 0
    }
}
