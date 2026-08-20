import Foundation
import SQLite3
import Testing

@testable import XFinder

@Test func parsesClaudeUserAndAssistantLines() {
    let userLine = #"{"type":"user","cwd":"/p","message":{"content":"hello there"}}"#
    let asstLine = #"{"type":"assistant","message":{"content":[{"type":"text","text":"hi back"}]}}"#

    let u = SessionParsing.message(fromLine: userLine)
    #expect(u?.role == .user)
    #expect(u?.text == "hello there")

    let a = SessionParsing.message(fromLine: asstLine)
    #expect(a?.role == .assistant)
    #expect(a?.text == "hi back")

    #expect(SessionParsing.cwd(fromLine: userLine) == "/p")
}

@Test func parsesCodexResponseItemLines() {
    let line =
        #"{"timestamp":"t","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"do the thing"}]}}"#
    let m = SessionParsing.message(fromLine: line)
    #expect(m?.role == .user)
    #expect(m?.text == "do the thing")

    let meta = #"{"type":"session_meta","payload":{"cwd":"/work/proj","id":"x"}}"#
    #expect(SessionParsing.cwd(fromLine: meta) == "/work/proj")
}

@Test func skipsToolAndNonMessageLines() {
    #expect(SessionParsing.message(fromLine: #"{"type":"summary","summary":"x"}"#) == nil)
    #expect(SessionParsing.message(fromLine: #"{"payload":{"type":"function_call","call_id":"1"}}"#) == nil)
    #expect(SessionParsing.message(fromLine: "not json") == nil)
}

@Test func detectsPreambleTitles() {
    #expect(SessionParsing.isPreamble("# AGENTS.md instructions for /x"))
    #expect(SessionParsing.isPreamble("<system-reminder>do x</system-reminder>"))
    #expect(SessionParsing.isPreamble("# Files mentioned by the user:\n## clip.png"))
    #expect(SessionParsing.isPreamble("<INSTRUCTIONS>\n全局协作纪律"))
    #expect(!SessionParsing.isPreamble("帮我设计一个搜索后台"))
}

@Test func stripsPreambleTurnsKeepingRealConversation() {
    let messages = [
        SessionMessage(id: 0, role: .user, text: "# AGENTS.md instructions for /x"),
        SessionMessage(id: 1, role: .user, text: "# Files mentioned by the user:\n## a.png"),
        SessionMessage(id: 2, role: .user, text: "为啥网络访问不了"),
        SessionMessage(id: 3, role: .assistant, text: "因为…"),
    ]
    let kept = SessionParsing.stripPreamble(messages)
    #expect(kept.map(\.text) == ["为啥网络访问不了", "因为…"])
}

@Test func estimatesTokens() {
    #expect(SessionParsing.estimateTokens(chars: 400) == 100)
    #expect(SessionParsing.estimateTokens(bytes: 4096) == 1024)
}

@Test func sessionCatalogReusesPersistentMetadataUntilAFileChanges() async throws {
    let base = FileManager.default.temporaryDirectory
        .appendingPathComponent("XFinderSessionCatalog-\(UUID().uuidString)", isDirectory: true)
    let root = base.appendingPathComponent("sessions", isDirectory: true)
    let cacheURL = base.appendingPathComponent("support/session-catalog.json")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: base) }

    let sessionURL = root.appendingPathComponent("session.jsonl")
    let first = #"{"type":"user","cwd":"/work/project","message":{"content":"first"}}"# + "\n"
    let second = #"{"type":"user","cwd":"/work/project","message":{"content":"other"}}"# + "\n"
    #expect(first.utf8.count == second.utf8.count)
    try first.write(to: sessionURL, atomically: true, encoding: .utf8)
    let originalDate = try #require(
        sessionURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
    let sources = [SessionScanSource(agent: .codex, roots: [root])]

    let initialCatalog = SessionCatalog(cacheURL: cacheURL, sources: sources)
    let initial = await initialCatalog.sessions()
    #expect(initial.map(\.title) == ["first"])
    #expect(await initialCatalog.metrics() == SessionCatalogMetrics(reusedFileCount: 0, parsedFileCount: 1))
    #expect(FileManager.default.fileExists(atPath: cacheURL.path))

    // A fresh actor proves the metadata came from the on-disk cache, not memory.
    let relaunchedCatalog = SessionCatalog(cacheURL: cacheURL, sources: sources)
    let cached = await relaunchedCatalog.sessions()
    #expect(cached.map(\.title) == ["first"])
    #expect(await relaunchedCatalog.metrics() == SessionCatalogMetrics(reusedFileCount: 1, parsedFileCount: 0))

    // Once metadata changes, a forced refresh reparses only that file.
    try second.write(to: sessionURL, atomically: true, encoding: .utf8)
    let changedDate = originalDate.addingTimeInterval(2)
    try FileManager.default.setAttributes([.modificationDate: changedDate], ofItemAtPath: sessionURL.path)
    let refreshed = await relaunchedCatalog.sessions(force: true)
    #expect(refreshed.map(\.title) == ["other"])
    #expect(await relaunchedCatalog.metrics() == SessionCatalogMetrics(reusedFileCount: 0, parsedFileCount: 1))
}

@Test func codexTitleCatalogPrefersDesktopDisplayTitleAndFallsBackToState() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("XFinderCodexTitles-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let stateURL = directory.appendingPathComponent("state.sqlite")
    let catalogURL = directory.appendingPathComponent("catalog.sqlite")

    try createSQLiteDatabase(
        at: stateURL,
        sql: """
            CREATE TABLE threads (id TEXT PRIMARY KEY, title TEXT NOT NULL, name TEXT);
            INSERT INTO threads VALUES ('thread-a', 'State A', NULL);
            INSERT INTO threads VALUES ('thread-b', 'State B', NULL);
            """)
    try createSQLiteDatabase(
        at: catalogURL,
        sql: """
            CREATE TABLE local_thread_catalog (
                host_id TEXT, thread_id TEXT, display_title TEXT, missing_candidate INTEGER
            );
            INSERT INTO local_thread_catalog VALUES ('local', 'thread-a', 'Codex A', 0);
            INSERT INTO local_thread_catalog VALUES ('remote', 'thread-b', 'Remote B', 0);
            """)

    let titles = CodexThreadTitleCatalog.load(
        catalogDatabaseURLs: [catalogURL],
        stateDatabaseURLs: [stateURL])
    #expect(titles["thread-a"] == "Codex A")
    #expect(titles["thread-b"] == "State B")
}

@Test func codexCanonicalTitleOverridesAnUnchangedSessionCache() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("XFinderCodexTitleCache-\(UUID().uuidString)", isDirectory: true)
    let root = directory.appendingPathComponent("sessions", isDirectory: true)
    let cacheURL = directory.appendingPathComponent("cache/session-catalog.json")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let threadID = "019ea09a-392b-7d42-8eab-f93bb4321c12"
    let sessionURL = root.appendingPathComponent("rollout-2026-08-20T10-00-00-\(threadID).jsonl")
    try (#"{"type":"user","cwd":"/work/project","message":{"content":"First prompt"}}"# + "\n")
        .write(to: sessionURL, atomically: true, encoding: .utf8)
    let sources = [SessionScanSource(agent: .codex, roots: [root])]

    let initial = await SessionScanner.scan(
        sources: sources,
        cacheURL: cacheURL,
        codexTitles: [threadID: "Generated title"])
    let renamed = await SessionScanner.scan(
        sources: sources,
        cacheURL: cacheURL,
        codexTitles: [threadID: "Renamed title"])

    #expect(initial.map(\.title) == ["Generated title"])
    #expect(renamed.map(\.title) == ["Renamed title"])
}

private func createSQLiteDatabase(at url: URL, sql: String) throws {
    var database: OpaquePointer?
    guard sqlite3_open(url.path, &database) == SQLITE_OK, let database else {
        throw NSError(domain: "XFinderTests.SQLite", code: 1)
    }
    defer { sqlite3_close(database) }
    var errorMessage: UnsafeMutablePointer<CChar>?
    let result = sqlite3_exec(database, sql, nil, nil, &errorMessage)
    guard result == SQLITE_OK else {
        let message = errorMessage.map { String(cString: $0) } ?? "Unknown SQLite error"
        sqlite3_free(errorMessage)
        throw NSError(domain: "XFinderTests.SQLite", code: Int(result), userInfo: [NSLocalizedDescriptionKey: message])
    }
}

@Test func transcriptReaderKeepsHeadAndTailWithinHardLimits() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("XFinderTranscript-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("large.jsonl")

    func line(_ text: String) -> String {
        #"{"type":"user","cwd":"/work/project","message":{"content":""# + text + #""}}"# + "\n"
    }
    let content =
        line("first")
        + (0..<20).map { line("middle-\($0)-" + String(repeating: "x", count: 80)) }.joined()
        + line("last")
    try Data(content.utf8).write(to: url)

    let transcript = await SessionScanner.transcript(
        for: url,
        limits: SessionTranscriptLimits(
            maximumReadBytes: 420,
            leadingReadBytes: 140,
            maximumMessages: 20,
            maximumCharacters: 2_000
        ))

    #expect(transcript.wasTruncated)
    #expect(transcript.messages.first?.text == "first")
    #expect(transcript.messages.last?.text == "last")
    #expect(!transcript.messages.contains { $0.text.contains("middle-0-") })
}

@Test func sessionMarkdownRenderingSupportsRichBlocksAndOmitsImages() throws {
    let transcript = SessionTranscript(
        messages: [
            SessionMessage(
                id: 0,
                role: .assistant,
                text: """
                    # Result

                    | File | State |
                    | --- | --- |
                    | a.swift | Changed |

                    ```swift
                    print("ok")
                    ```

                    ![private diagram](file:///tmp/private.png)
                    """)
        ],
        exactTokens: 20
    )

    let rendered = SessionMarkdownRendering.renderSynchronously(transcript)
    let blocks = try #require(rendered.turns.first?.document.blocks)
    #expect(blocks.contains { if case .heading = $0.kind { true } else { false } })
    #expect(blocks.contains { if case .table = $0.kind { true } else { false } })
    #expect(blocks.contains { if case .code = $0.kind { true } else { false } })
    #expect(!blocks.contains { if case .image = $0.kind { true } else { false } })
    #expect(MarkdownExportLogic.plainText(from: rendered.turns[0].document).contains("Image: private diagram"))
}

@Test func sessionMarkdownRenderingGroupsConsecutiveMessagesIntoConversationTurns() throws {
    let transcript = SessionTranscript(
        messages: [
            SessionMessage(id: 0, role: .user, text: "Question"),
            SessionMessage(id: 1, role: .assistant, text: "First part"),
            SessionMessage(id: 2, role: .assistant, text: "Second part"),
            SessionMessage(id: 3, role: .user, text: "Follow-up"),
        ],
        exactTokens: 10
    )

    let rendered = SessionMarkdownRendering.renderSynchronously(transcript)
    #expect(rendered.turns.map(\.role) == [.user, .assistant, .user])
    #expect(rendered.turns.map(\.id) == [0, 1, 3])
    let assistantText = MarkdownExportLogic.plainText(from: rendered.turns[1].document)
    #expect(assistantText.contains("First part"))
    #expect(assistantText.contains("Second part"))
    #expect(SessionMarkdownRendering.source(from: transcript).components(separatedBy: "## Assistant").count == 2)
}

@Test func sessionMarkdownRenderingCapsMessagesAndCopySourceKeepsRoles() async throws {
    let transcript = SessionTranscript(
        messages: [
            SessionMessage(id: 0, role: .user, text: "First request"),
            SessionMessage(id: 1, role: .assistant, text: "Second response"),
        ],
        exactTokens: 10
    )
    let limits = SessionMarkdownLimits(
        maximumMessages: 1,
        maximumTotalCharacters: 5,
        maximumCharactersPerTurn: 5,
        maximumBlocksPerTurn: 10
    )

    let rendered = SessionMarkdownRendering.renderSynchronously(transcript, limits: limits)
    #expect(rendered.turns.count == 1)
    #expect(rendered.wasTruncated)
    #expect(SessionMarkdownRendering.source(from: transcript).contains("## User\n\nFirst request"))
    #expect(SessionMarkdownRendering.source(from: transcript).contains("## Assistant\n\nSecond response"))
    let asyncSource = try #require(await SessionMarkdownRendering.sourceAsync(from: transcript))
    #expect(asyncSource == SessionMarkdownRendering.source(from: transcript))
}

@Test func llmRequestBuildsOpenAICompatibleCall() throws {
    var config = SummaryLLMConfig()
    config.enabled = true
    config.apiKey = "sk-test"
    config.baseURL = "https://api.example.com/v1/"  // trailing slash tolerated
    config.model = "gpt-4o-mini"

    let request = try SummaryLLMClient.makeRequest(config: config, system: "sys", user: "hi")
    #expect(request.url?.absoluteString == "https://api.example.com/v1/chat/completions")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-test")

    let body = try #require(request.httpBody)
    let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
    #expect(json["model"] as? String == "gpt-4o-mini")
    let messages = try #require(json["messages"] as? [[String: String]])
    #expect(messages.count == 2)
    #expect(messages[0]["role"] == "system")
}

@Test func llmRequestRequiresConfig() {
    var config = SummaryLLMConfig()  // disabled, no key
    #expect(throws: (any Error).self) {
        _ = try SummaryLLMClient.makeRequest(config: config, system: "s", user: "u")
    }
    config.enabled = true  // still no key
    #expect(throws: (any Error).self) {
        _ = try SummaryLLMClient.makeRequest(config: config, system: "s", user: "u")
    }
}

@Test func llmParsesChoiceContent() throws {
    let data = #"{"choices":[{"message":{"role":"assistant","content":"the summary"}}]}"#.data(using: .utf8)!
    #expect(SummaryLLMClient.parseContent(data) == "the summary")
    #expect(SummaryLLMClient.parseContent(Data("{}".utf8)) == nil)
}
