import Foundation
import Testing

@testable import XFinder

// MARK: - Line parsers

@Test func parsesClaudeUsageLine() {
    let line =
        #"{"type":"assistant","timestamp":"2026-09-10T08:30:00.000Z","message":{"model":"claude-sonnet-4-5-20250929","usage":{"input_tokens":1200,"output_tokens":300,"cache_read_input_tokens":5000,"cache_creation_input_tokens":800}}}"#
    let event = UsageLineParsing.event(fromLine: line, tool: .claude)
    #expect(event?.tool == .claude)
    #expect(event?.model == "claude-sonnet-4-5-20250929")
    #expect(event?.input == 1200)
    #expect(event?.output == 300)
    #expect(event?.cacheRead == 5000)
    #expect(event?.cacheWrite == 800)
    #expect(event != nil && event!.timestamp > .distantPast)

    // User lines and noise never produce usage events.
    #expect(UsageLineParsing.event(fromLine: #"{"type":"user","message":{"content":"hi"}}"#, tool: .claude) == nil)
    #expect(UsageLineParsing.event(fromLine: "plain text", tool: .claude) == nil)
}

@Test func parsesCodexTokenCountAndRateLimits() {
    let line =
        #"{"timestamp":"2026-07-17T16:04:50.222Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":16713,"total_tokens":16818},"last_token_usage":{"input_tokens":16713,"cached_input_tokens":11008,"output_tokens":105,"reasoning_output_tokens":28,"total_tokens":16818}},"rate_limits":{"primary":{"used_percent":36.0,"window_minutes":10080,"resets_at":1784790749},"plan_type":"pro"}}}"#
    let event = UsageLineParsing.event(fromLine: line, tool: .codex)
    #expect(event?.input == 16713)
    #expect(event?.cacheRead == 11008)
    #expect(event?.output == 105)
    #expect(event?.reasoning == 28)
    #expect(event?.rateLimit?.usedPercent == 36.0)
    #expect(event?.rateLimit?.windowMinutes == 10080)
    #expect(event?.rateLimit?.planType == "pro")
    #expect(event?.rateLimit?.resetsAt == Date(timeIntervalSince1970: 1784790749))

    // The model lives on turn_context lines.
    let context = #"{"type":"turn_context","payload":{"turn_id":"t1","model":"gpt-5.6-sol","effort":"high"}}"#
    #expect(UsageLineParsing.codexModel(fromLine: context) == "gpt-5.6-sol")
}

@Test func parsesKimiTurnUsageAndSkipsBookkeeping() {
    let line =
        #"{"type":"usage.record","model":"kimi-code/kimi-for-coding","usage":{"inputOther":274,"output":110,"inputCacheRead":20224,"inputCacheCreation":0},"usageScope":"turn","time":1785092339103}"#
    let event = UsageLineParsing.event(fromLine: line, tool: .kimi)
    #expect(event?.input == 274)
    #expect(event?.output == 110)
    #expect(event?.cacheRead == 20224)
    #expect(event?.model == "kimi-code/kimi-for-coding")
    #expect(event != nil && abs(event!.timestamp.timeIntervalSince1970 - 1785092339.103) < 0.01)

    // Session-scope records are bookkeeping (compaction) and must not count.
    let sessionScope =
        #"{"type":"usage.record","usage":{"inputOther":999999,"output":1,"inputCacheRead":0,"inputCacheCreation":0},"usageScope":"session","time":1785092339103}"#
    #expect(UsageLineParsing.event(fromLine: sessionScope, tool: .kimi) == nil)
}

@Test func parsesGrokInferenceDoneLine() {
    let line =
        #"{"ts":"2026-08-20T13:52:35.537Z","src":"shell","msg":"shell.turn.inference_done","ctx":{"loop_index":6,"prompt_tokens":356651,"cached_prompt_tokens":354304,"completion_tokens":1423,"reasoning_tokens":1420}}"#
    let event = UsageLineParsing.event(fromLine: line, tool: .grok)
    #expect(event?.input == 356651)
    #expect(event?.cacheRead == 354304)
    #expect(event?.output == 1423)
    #expect(event?.reasoning == 1420)
}

@Test func parsesGrokBillingCreditsConfigLine() {
    let line =
        #"{"ts":"2026-09-11T09:22:10.448Z","src":"shell","msg":"billing: fetched credits config","ctx":{"config":{"creditUsagePercent":59.0,"currentPeriod":{"type":"USAGE_PERIOD_TYPE_WEEKLY","start":"2026-09-07T06:30:32.536717+00:00","end":"2026-09-14T06:30:32.536717+00:00"},"prepaidBalance":{"val":0}},"subscriptionTier":"SuperGrok"}}"#
    let event = UsageLineParsing.event(fromLine: line, tool: .grok)
    // Quota-only line: no tokens and no day bucket (distantPast timestamp).
    #expect(event?.timestamp == .distantPast)
    #expect(event?.input == 0)
    let snapshot = event?.rateLimit
    #expect(snapshot?.usedPercent == 59.0)
    #expect(snapshot?.windowMinutes == 10080)
    #expect(snapshot?.planType == "SuperGrok")
    #expect(snapshot?.resetsAt != nil)
    #expect(snapshot?.capturedAt == UsageLineParsing.isoDate("2026-09-11T09:22:10.448Z"))
}

@Test func grokNoiseLinesProduceNoEvent() {
    let line =
        #"{"ts":"2026-09-11T09:22:10.448Z","src":"shell","msg":"shell.tool.exec_done","ctx":{"command":"ls"}}"#
    #expect(UsageLineParsing.event(fromLine: line, tool: .grok) == nil)
}

@Test func parsesZCodeInclusiveCounts() {
    // ZCode's input already includes cache buckets; output includes reasoning.
    let line =
        #"{"role":"assistant","model":"GLM-5.2","timestamp":"2026-09-01T10:00:00Z","usage":{"input_tokens":100,"output_tokens":20,"reasoning_tokens":5,"input_cache_read":7,"input_cache_creation":3,"total_tokens":120}}"#
    let event = UsageLineParsing.event(fromLine: line, tool: .glm)
    #expect(event?.input == 90)  // 100 - 7 - 3
    #expect(event?.output == 15)  // 20 - 5
    #expect(event?.cacheRead == 7)
    #expect(event?.cacheWrite == 3)
    #expect(event?.reasoning == 5)
    #expect(event?.model == "GLM-5.2")
}

@Test func parsesCopilotOTelSpan() {
    let line =
        #"{"type":"span","spanId":"span-1","name":"chat claude-sonnet-4","startTime":[1775934260,133000000],"attributes":{"gen_ai.operation.name":"chat","gen_ai.response.model":"claude-sonnet-4.6","gen_ai.response.id":"interaction-1","gen_ai.usage.input_tokens":21884,"gen_ai.usage.output_tokens":"80","gen_ai.usage.cache_read.input_tokens":123,"gen_ai.usage.cache_creation.input_tokens":21881,"gen_ai.usage.reasoning.output_tokens":128}}"#
    let event = UsageLineParsing.event(fromLine: line, tool: .copilot)
    #expect(event?.input == 21884)
    #expect(event?.output == 80)  // string numbers are accepted
    #expect(event?.cacheRead == 123)
    #expect(event?.cacheWrite == 21881)
    #expect(event?.reasoning == 128)
    #expect(event?.model == "claude-sonnet-4.6")
    #expect(event?.dedupeKey == "interaction-1")
    #expect(event != nil && abs(event!.timestamp.timeIntervalSince1970 - 1775934260.133) < 0.01)
}

@Test func parsesAntigravityCacheLine() {
    let line =
        #"{"type":"usage","sessionId":"abc","timestamp":1711200000000,"modelId":"gemini-3-flash-a","input":12,"output":4,"cacheRead":2,"cacheWrite":0,"reasoning":1,"responseId":"resp-1"}"#
    let event = UsageLineParsing.event(fromLine: line, tool: .antigravity)
    #expect(event?.input == 12)
    #expect(event?.output == 4)
    #expect(event?.cacheRead == 2)
    #expect(event?.reasoning == 1)
    #expect(event?.model == "gemini-3-flash-a")
    #expect(event?.dedupeKey == "resp-1")

    // session_meta lines are not usage.
    #expect(
        UsageLineParsing.event(
            fromLine: #"{"type":"session_meta","sessionId":"abc","modelId":"x"}"#, tool: .antigravity)
            == nil)
}

// MARK: - Whole-file parsers

@Test func parsesCursorUsageExport() {
    let json = """
        {"totalUsageEventsCount": 2, "usageEventsDisplay": [
          {"timestamp": "1788171994838", "model": "cursor-grok-4.6-high",
           "tokenUsage": {"inputTokens": 22252, "outputTokens": 4283, "cacheReadTokens": 1379927, "cacheWriteTokens": 512}},
          {"timestamp": 1788172000000, "model": "gpt-5",
           "tokenUsage": {"inputTokens": 10, "outputTokens": 5}}
        ]}
        """
    let events = UsageToolParsers.cursorEvents(fromFileText: json)
    #expect(events.count == 2)
    #expect(events[0].input == 22252)
    #expect(events[0].cacheRead == 1379927)
    #expect(events[0].cacheWrite == 512)
    #expect(events[0].model == "cursor-grok-4.6-high")
    #expect(events[1].timestamp == Date(timeIntervalSince1970: 1788172000))
    #expect(UsageToolParsers.cursorEvents(fromFileText: "{}").isEmpty)
}

@Test func parsesOpenCodeMessageJSON() {
    let v2 = """
        {"id": "msg-1", "time": {"created": 1783882279705.5}, "agent": "build",
         "model": {"id": "claude-sonnet-4", "providerID": "anthropic"},
         "tokens": {"input": 5519, "output": 20, "reasoning": 23, "cache": {"read": 100, "write": 50}}}
        """
    let object = try? JSONSerialization.jsonObject(with: Data(v2.utf8)) as? [String: Any]
    let event = object.flatMap { UsageToolParsers.opencodeEvent(from: $0) }
    #expect(event?.input == 5519)
    #expect(event?.output == 20)
    #expect(event?.reasoning == 23)
    #expect(event?.cacheRead == 100)
    #expect(event?.cacheWrite == 50)
    #expect(event?.model == "claude-sonnet-4")
    #expect(event?.dedupeKey == "msg-1")

    // Non-assistant roles never count.
    let userObject = ["role": "user", "tokens": ["input": 1]] as [String: Any]
    #expect(UsageToolParsers.opencodeEvent(from: userObject) == nil)
}

@Test func kimiCLIKeepsLatestCumulativeSnapshotPerMessage() {
    let text = """
        {"timestamp":1770983426.0,"message":{"type":"StatusUpdate","payload":{"token_usage":{"input_other":100,"output":10,"input_cache_read":0,"input_cache_creation":0},"message_id":"m1"}}}
        {"timestamp":1770983427.0,"message":{"type":"StatusUpdate","payload":{"token_usage":{"input_other":1562,"output":2463,"input_cache_read":0,"input_cache_creation":0},"message_id":"m1"}}}
        {"timestamp":1770983428.0,"message":{"type":"StatusUpdate","payload":{"token_usage":{"input_other":5,"output":2,"input_cache_read":0,"input_cache_creation":0},"message_id":"m2"}}}
        {"type":"unrelated"}
        """
    let events = UsageToolParsers.kimiCLIEvents(fromFileText: text)
    #expect(events.count == 2)
    let m1 = events.first { $0.output == 2463 }
    #expect(m1?.input == 1562)  // latest snapshot wins, not the sum
    #expect(events.contains { $0.input == 5 })
}

@Test func replaysCopilotChatSessionPatches() {
    let text = """
        {"kind":0,"v":{"requests":[{"requestId":"r1","timestamp":1783918304896,"modelId":"copilot/auto","completionTokens":154,"promptTokens":22079}]}}
        {"kind":2,"k":["requests"],"v":[{"requestId":"r2","timestamp":1783918400000,"result":{"metadata":{"promptTokens":100,"outputTokens":10,"resolvedModel":"gpt-5.3-codex","toolCallRounds":[{"thinking":{"tokens":88}}]}}}]}
        {"kind":1,"k":["requests",0,"promptTokens"],"v":25000}
        {"kind":1,"k":["requests",0,"irrelevant"],"v":1}
        """
    let events = UsageToolParsers.copilotChatSessionEvents(fromFileText: text)
    #expect(events.count == 2)
    let r1 = events.first { $0.dedupeKey == "r1" }
    #expect(r1?.input == 25000)  // the kind:1 patch overwrites the snapshot value
    #expect(r1?.output == 154)
    let r2 = events.first { $0.dedupeKey == "r2" }
    #expect(r2?.input == 100)
    #expect(r2?.reasoning == 88)
    #expect(r2?.model == "gpt-5.3-codex")
}

// MARK: - Aggregation

@Test func aggregatesByToolModelAndDayWindow() {
    let today = UsageDayKey.make(for: Date())
    let old = UsageDayKey.offset(-40)
    var files: [String: UsageFileContribution] = [:]
    var recent = UsageFileContribution(offset: 1, modified: Date())
    recent.days = [
        today: ["kimi-code/kimi-for-coding": UsageTotals(input: 10, output: 5)],
        old: ["kimi-code/kimi-for-coding": UsageTotals(input: 1000, output: 500)],
    ]
    files["kimi:/a/wire.jsonl"] = recent
    var other = UsageFileContribution(offset: 1, modified: Date())
    other.days = [today: ["": UsageTotals(input: 3, output: 1)]]
    files["grok:/b/unified.jsonl"] = other

    let all = UsageAggregation.totals(files: files)
    #expect(all.input == 1013)
    let last30 = UsageAggregation.totals(files: files, sinceDay: UsageDayKey.offset(-29))
    #expect(last30.input == 13)

    let byTool = UsageAggregation.totalsByTool(files: files, sinceDay: UsageDayKey.offset(-29))
    #expect(byTool[.kimi]?.input == 10)
    #expect(byTool[.grok]?.input == 3)

    let kimiModels = UsageAggregation.totalsByModel(files: files, tool: .kimi)
    #expect(kimiModels["kimi-code/kimi-for-coding"]?.output == 505)

    // Unknown ("") model buckets fall back to the tool's pricing entry.
    let models = UsageAggregation.totalsByModel(files: files, sinceDay: UsageDayKey.offset(-29))
    #expect(models["grok"]?.input == 3)
}

@Test func dailySeriesFillsEmptyDays() {
    let series = UsageAggregation.dailySeries(files: [:], days: 7)
    #expect(series.count == 7)
    #expect(series.last?.day == UsageDayKey.make(for: Date()))
    #expect(series.allSatisfy { $0.totals.total == 0 })
}

@Test func costEstimationFlagsUnknownModels() {
    let known = UsageTotals(input: 1_000_000, output: 1_000_000)
    let cost = UsageAggregation.costUSD(modelTotals: ["claude-sonnet-4-5": known])
    // 3 USD in + 15 USD out = 18 USD.
    #expect(cost.complete)
    #expect(abs(cost.value - 18) < 0.001)

    let unknown = UsageAggregation.costUSD(modelTotals: ["mystery-model": known])
    #expect(!unknown.complete)
    #expect(unknown.value == 0)
}

@Test func ledgerPrunesOldDayBuckets() {
    var ledger = UsageLedger()
    var entry = UsageFileContribution(offset: 1, modified: Date())
    entry.days = [
        UsageDayKey.offset(-400): ["m": UsageTotals(input: 1)],
        UsageDayKey.offset(-10): ["m": UsageTotals(input: 2)],
    ]
    ledger.files["kimi:/x"] = entry
    ledger.prune(olderThan: UsageDayKey.offset(-370))
    #expect(ledger.files["kimi:/x"]?.days.count == 1)
    #expect(ledger.files["kimi:/x"]?.days[UsageDayKey.offset(-10)] != nil)
}

// MARK: - Scanner (temp directories only)

private func makeTempDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("xfinder-usage-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private let codexLine =
    #"{"timestamp":"2026-09-10T08:30:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":100,"cached_input_tokens":40,"output_tokens":10,"reasoning_output_tokens":3}}}}"#

@Test func scannerReadsIncrementallyWithoutDoubleCounting() async throws {
    let root = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let ledgerURL = root.appendingPathComponent("ledger.json")
    let log = root.appendingPathComponent("rollout.jsonl")
    let day = UsageDayKey.make(for: UsageLineParsing.isoDate("2026-09-10T08:30:00.000Z")!)

    try Data((codexLine + "\n").utf8).write(to: log)
    let sources = [TokenUsageScanSource(tool: .codex, roots: [root])]

    let first = await TokenUsageScanner.scan(sources: sources, ledgerURL: ledgerURL, retentionDays: 370)
    let key = UsageFileKey.make(tool: .codex, url: log)
    #expect(first.ledger.files[key]?.days[day]?[""]?.input == 100)
    #expect(first.metrics.scannedFiles == 1)

    // Unchanged file: fully reused, zero bytes read.
    let second = await TokenUsageScanner.scan(sources: sources, ledgerURL: ledgerURL, retentionDays: 370)
    #expect(second.ledger.files[key]?.days[day]?[""]?.input == 100)
    #expect(second.metrics.reusedFiles == 1)
    #expect(second.metrics.bytesRead == 0)

    // Appended line: only the tail is read, totals accumulate exactly once.
    let handle = try FileHandle(forWritingTo: log)
    try handle.seekToEnd()
    try handle.write(Data((codexLine + "\n").utf8))
    try handle.close()
    let third = await TokenUsageScanner.scan(sources: sources, ledgerURL: ledgerURL, retentionDays: 370)
    #expect(third.ledger.files[key]?.days[day]?[""]?.input == 200)
    #expect(third.metrics.bytesRead == Int64(codexLine.utf8.count + 1))
}

@Test func scannerReplacesContributionWhenFileIsRewritten() async throws {
    let root = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let ledgerURL = root.appendingPathComponent("ledger.json")
    let log = root.appendingPathComponent("rollout.jsonl")
    let day = UsageDayKey.make(for: UsageLineParsing.isoDate("2026-09-10T08:30:00.000Z")!)
    let sources = [TokenUsageScanSource(tool: .codex, roots: [root])]

    try Data((codexLine + "\n" + codexLine + "\n").utf8).write(to: log)
    _ = await TokenUsageScanner.scan(sources: sources, ledgerURL: ledgerURL, retentionDays: 370)

    // Rewriting with less content (smaller size) rescans from zero and
    // replaces — the old contribution must not linger.
    try Data((codexLine + "\n").utf8).write(to: log, options: .atomic)
    let result = await TokenUsageScanner.scan(sources: sources, ledgerURL: ledgerURL, retentionDays: 370)
    let key = UsageFileKey.make(tool: .codex, url: log)
    #expect(result.ledger.files[key]?.days[day]?[""]?.input == 100)
}

@Test func scannerKeepsContributionsOfDeletedFiles() async throws {
    let root = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let ledgerURL = root.appendingPathComponent("ledger.json")
    let log = root.appendingPathComponent("rollout.jsonl")
    let sources = [TokenUsageScanSource(tool: .codex, roots: [root])]

    try Data((codexLine + "\n").utf8).write(to: log)
    _ = await TokenUsageScanner.scan(sources: sources, ledgerURL: ledgerURL, retentionDays: 370)

    try FileManager.default.removeItem(at: log)
    let result = await TokenUsageScanner.scan(sources: sources, ledgerURL: ledgerURL, retentionDays: 370)
    // The file is gone from disk but its recorded usage survives (the tools'
    // own retention cleanup must not erase history we already observed).
    #expect(UsageAggregation.totals(files: result.ledger.files).input == 100)
}

@Test func scannerReadsWholeFileSources() async throws {
    let root = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let ledgerURL = root.appendingPathComponent("ledger.json")
    // A legacy Kimi CLI wire log (whole-file strategy: cumulative snapshots).
    let log = root.appendingPathComponent("wire.jsonl")
    let text = """
        {"timestamp":1770983426.0,"message":{"type":"StatusUpdate","payload":{"token_usage":{"input_other":100,"output":10,"input_cache_read":0,"input_cache_creation":0},"message_id":"m1"}}}
        {"timestamp":1770983427.0,"message":{"type":"StatusUpdate","payload":{"token_usage":{"input_other":300,"output":30,"input_cache_read":0,"input_cache_creation":0},"message_id":"m1"}}}

        """
    try Data(text.utf8).write(to: log)
    let sources = [TokenUsageScanSource(tool: .kimi, roots: [root])]
    let result = await TokenUsageScanner.scan(sources: sources, ledgerURL: ledgerURL, retentionDays: 370)
    // Latest cumulative snapshot wins: 300, not 100 + 300.
    #expect(UsageAggregation.totals(files: result.ledger.files).input == 300)
}
