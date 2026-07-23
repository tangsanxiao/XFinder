import AppKit
import CoreGraphics
import CoreText
import Foundation
import Testing

@testable import XFinder

@Test func readAloudKindDetectsDocumentsAndDeveloperText() {
    #expect(
        ReadAloudFileKind.detect(url: URL(fileURLWithPath: "/tmp/notes.md"), isDirectory: false, isPackage: false)
            == .markdown)
    #expect(
        ReadAloudFileKind.detect(url: URL(fileURLWithPath: "/tmp/main.swift"), isDirectory: false, isPackage: false)
            == .plainText)
    #expect(
        ReadAloudFileKind.detect(url: URL(fileURLWithPath: "/tmp/session.jsonl"), isDirectory: false, isPackage: false)
            == .plainText)
    #expect(
        ReadAloudFileKind.detect(url: URL(fileURLWithPath: "/tmp/guide.pdf"), isDirectory: false, isPackage: false)
            == .pdf)
    #expect(
        ReadAloudFileKind.detect(url: URL(fileURLWithPath: "/tmp/archive.zip"), isDirectory: false, isPackage: false)
            == nil)
    #expect(
        ReadAloudFileKind.detect(url: URL(fileURLWithPath: "/tmp/folder"), isDirectory: true, isPackage: false) == nil)
}

@Test func markdownCleaningRemovesPresentationSyntaxButKeepsContent() {
    let markdown = """
        ---
        title: Hidden metadata
        ---
        # Read Aloud

        - Visit [Apple](https://apple.com) and use `AVSpeechSynthesizer`.
        ```swift
        let enabled = true
        ```
        """

    let cleaned = ReadAloudTextLogic.cleanedText(markdown, kind: .markdown)

    #expect(!cleaned.contains("Hidden metadata"))
    #expect(!cleaned.contains("https://"))
    #expect(!cleaned.contains("```"))
    #expect(cleaned.contains("Read Aloud"))
    #expect(cleaned.contains("Visit Apple and use AVSpeechSynthesizer."))
    #expect(cleaned.contains("let enabled = true"))
}

@Test func textChunkingIsBoundedAndPrefersReadableBreaks() {
    let text =
        "First sentence is short. Second sentence is longer and should be divided near punctuation.\n\nFinal paragraph."
    let chunks = ReadAloudTextLogic.chunks(from: text, maximumCharacters: 32)

    #expect(chunks.count > 2)
    #expect(chunks.allSatisfy { !$0.isEmpty && $0.count <= 32 })
    #expect(chunks.joined(separator: " ").contains("Final paragraph."))
}

@Test func languageDetectionOnlySelectsChineseForMeaningfulCJKContent() {
    #expect(ReadAloudTextLogic.preferredLanguageCode(for: "这是一个用于朗读的中文段落。") == "zh-CN")
    #expect(ReadAloudTextLogic.preferredLanguageCode(for: "This is an English paragraph.") == nil)
}

@Test func htmlCleaningRemovesScriptsAndKeepsVisibleText() {
    let html =
        "<html><style>body{display:none}</style><body><h1>Title</h1><script>alert(1)</script><p>A &amp; B</p></body></html>"
    let cleaned = ReadAloudTextLogic.cleanedText(html, kind: .html)

    #expect(cleaned.contains("Title"))
    #expect(cleaned.contains("A & B"))
    #expect(!cleaned.contains("display:none"))
    #expect(!cleaned.contains("alert(1)"))
}

@Test func readableContentLoadsMarkdownWithConfiguredBounds() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("XFinderReadAloud-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("notes.md")
    try "# Title\n\nThis is a deliberately longer paragraph for a bounded reading test.".write(
        to: url,
        atomically: true,
        encoding: .utf8
    )
    let limits = ReadAloudLimits(
        maximumTextFileBytes: 1_024,
        maximumPDFFileBytes: 1_024,
        maximumPDFPages: 2,
        maximumExtractedCharacters: 36,
        maximumChunkCharacters: 18
    )

    let document = try await ReadableContentService.load(from: url, kind: .markdown, limits: limits)

    #expect(document.wasTruncated)
    #expect(document.chunks.allSatisfy { $0.count <= 18 })
    #expect(document.chunks.joined(separator: " ").contains("Title"))
}

@Test func readableContentRejectsBinaryAndOversizedFiles() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("XFinderReadAloud-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let binaryURL = root.appendingPathComponent("binary.txt")
    try Data([0, 1, 2, 3, 4, 5]).write(to: binaryURL)
    #expect(throws: ReadAloudError.cannotDecodeText) {
        try ReadableContentService.loadSynchronously(from: binaryURL, kind: .plainText)
    }

    let largeURL = root.appendingPathComponent("large.txt")
    try Data(repeating: 65, count: 32).write(to: largeURL)
    var limits = ReadAloudLimits.standard
    limits.maximumTextFileBytes = 8
    #expect(throws: ReadAloudError.fileTooLarge(maximumBytes: 8)) {
        try ReadableContentService.loadSynchronously(from: largeURL, kind: .plainText, limits: limits)
    }
}

@Test func readableContentCacheInvalidatesWhenFileChanges() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("XFinderReadAloud-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("cache.txt")
    try "first".write(to: url, atomically: true, encoding: .utf8)
    let first = try await ReadableContentService.load(from: url, kind: .plainText)

    try "second value".write(to: url, atomically: true, encoding: .utf8)
    let second = try await ReadableContentService.load(from: url, kind: .plainText)

    #expect(first.chunks == ["first"])
    #expect(second.chunks == ["second value"])
}

@Test func readableContentExtractsRTFAndSearchablePDF() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("XFinderReadAloud-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let rtfURL = root.appendingPathComponent("document.rtf")
    let source = NSAttributedString(string: "Readable RTF text")
    let rtfData = try source.data(
        from: NSRange(location: 0, length: source.length),
        documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
    )
    try rtfData.write(to: rtfURL)
    let rtf = try ReadableContentService.loadSynchronously(from: rtfURL, kind: .rtf)

    let pdfURL = root.appendingPathComponent("document.pdf")
    try writeSearchablePDF("Readable PDF text", to: pdfURL)
    let pdf = try ReadableContentService.loadSynchronously(from: pdfURL, kind: .pdf)

    #expect(rtf.chunks.joined(separator: " ").contains("Readable RTF text"))
    #expect(pdf.chunks.joined(separator: " ").contains("Readable PDF text"))
}

@Test func doubaoRequestUsesV3SSEAndKeepsCredentialOutOfBody() throws {
    let config = DoubaoTTSConfig(
        enabled: true,
        apiKey: "local-secret-key",
        resourceID: "seed-tts-2.0",
        voiceID: "zh_female_vv_uranus_bigtts"
    )

    let request = try DoubaoTTSClient.makeRequest(text: "你好，XFinder。", speed: 1.25, config: config)
    let body = try #require(request.httpBody)
    let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
    let parameters = try #require(object["req_params"] as? [String: Any])

    #expect(request.url == DoubaoTTSClient.endpoint)
    #expect(request.value(forHTTPHeaderField: "X-Api-Key") == "local-secret-key")
    #expect(request.value(forHTTPHeaderField: "X-Api-Resource-Id") == "seed-tts-2.0")
    #expect(parameters["speaker"] as? String == "zh_female_vv_uranus_bigtts")
    #expect(parameters["speed_ratio"] as? Double == 1.25)
    #expect(!String(decoding: body, as: UTF8.self).contains("local-secret-key"))
}

@Test func doubaoSSEParserJoinsAudioFramesAndEnforcesLimit() throws {
    let first = Data([1, 2, 3]).base64EncodedString()
    let second = Data([4, 5]).base64EncodedString()
    let response = Data(
        """
        event: 352
        data: {"data":"\(first)"}

        event: 352
        data: {"data":"\(second)"}

        event: 152
        data: {"code":20000000,"message":"ok"}

        """.utf8
    )

    #expect(try DoubaoTTSClient.parseSSEAudio(response) == Data([1, 2, 3, 4, 5]))
    #expect(throws: DoubaoTTSClientError.responseTooLarge) {
        try DoubaoTTSClient.parseSSEAudio(response, maximumAudioBytes: 4)
    }
}

@Test func doubaoSSEParserSurfacesServiceFailure() {
    let response = Data(
        """
        event: 153
        data: {"message":"voice is unavailable"}

        """.utf8
    )

    #expect(throws: DoubaoTTSClientError.service("voice is unavailable")) {
        try DoubaoTTSClient.parseSSEAudio(response)
    }
}

@MainActor
private final class FakeReadAloudSpeechEngine: ReadAloudSpeechEngine {
    weak var delegate: (any ReadAloudSpeechEngineDelegate)?
    private(set) var requests: [ReadAloudSpeechRequest] = []
    private(set) var pauseCount = 0
    private(set) var resumeCount = 0
    private(set) var stopCount = 0

    func speak(_ request: ReadAloudSpeechRequest) {
        requests.append(request)
    }

    func pause() -> Bool {
        pauseCount += 1
        return true
    }

    func resume() -> Bool {
        resumeCount += 1
        return true
    }

    func stop() -> Bool {
        stopCount += 1
        return true
    }

    func finishCurrent() {
        guard let requestID = requests.last?.id else { return }
        delegate?.speechEngineDidFinish(requestID: requestID)
    }
}

@MainActor
@Test func readAloudControllerAdvancesPausesAndCompletes() async {
    let engine = FakeReadAloudSpeechEngine()
    let url = URL(fileURLWithPath: "/tmp/read-me.md")
    let controller = ReadAloudController(engine: engine) { url, _, _ in
        ReadAloudDocument(url: url, chunks: ["First", "Second"], wasTruncated: false)
    }
    var events: [ReadAloudEvent] = []
    controller.onEvent = { events.append($0) }
    controller.setSpeed(.comfortable)

    controller.start(url: url, kind: .markdown)
    await waitForReadAloudTest { engine.requests.count == 1 }

    #expect(controller.phase == .playing)
    #expect(controller.currentChunkNumber == 1)
    #expect(engine.requests.first?.rateMultiplier == 1.25)

    controller.togglePause()
    #expect(controller.phase == .paused)
    #expect(engine.pauseCount == 1)
    controller.togglePause()
    #expect(controller.phase == .playing)
    #expect(engine.resumeCount == 1)

    engine.finishCurrent()
    #expect(engine.requests.count == 2)
    #expect(controller.currentChunkNumber == 2)
    engine.finishCurrent()

    #expect(controller.phase == .idle)
    #expect(controller.sourceURL == nil)
    #expect(events.contains(.completed("read-me.md")))
}

@MainActor
@Test func stoppingReadAloudCancelsPendingLoadWithoutSpeaking() async {
    let engine = FakeReadAloudSpeechEngine()
    let url = URL(fileURLWithPath: "/tmp/slow.md")
    let controller = ReadAloudController(engine: engine) { url, _, _ in
        try await Task.sleep(for: .seconds(5))
        return ReadAloudDocument(url: url, chunks: ["Late"], wasTruncated: false)
    }

    controller.start(url: url, kind: .markdown)
    controller.stop()
    await Task.yield()

    #expect(controller.phase == .idle)
    #expect(engine.requests.isEmpty)
    #expect(engine.stopCount >= 2)
}

@MainActor
@Test func doubaoFailureFallsBackOnceAndUsesCircuitBreakerForFollowingChunks() async {
    let systemEngine = FakeReadAloudSpeechEngine()
    let counter = DoubaoSynthesisCounter()
    let config = DoubaoTTSConfig(
        enabled: true,
        apiKey: "test-key",
        resourceID: "seed-tts-2.0",
        voiceID: "zh_female_vv_uranus_bigtts"
    )
    let hybrid = HybridReadAloudSpeechEngine(
        systemEngine: systemEngine,
        configProvider: { config },
        synthesizer: { _, _, _ in
            await counter.increment()
            throw ReadAloudTestError.networkUnavailable
        }
    )
    let url = URL(fileURLWithPath: "/tmp/fallback.md")
    let controller = ReadAloudController(engine: hybrid) { url, _, _ in
        ReadAloudDocument(url: url, chunks: ["First", "Second"], wasTruncated: false)
    }
    var events: [ReadAloudEvent] = []
    controller.onEvent = { events.append($0) }

    controller.start(url: url, kind: .markdown)
    await waitForReadAloudTest { systemEngine.requests.count == 1 }
    #expect(await counter.value == 1)
    #expect(events.contains(.fallback("The Internet connection appears to be offline.")))

    systemEngine.finishCurrent()
    #expect(systemEngine.requests.count == 2)
    #expect(await counter.value == 1)
    systemEngine.finishCurrent()
    #expect(controller.phase == .idle)
}

@MainActor
private func waitForReadAloudTest(_ condition: () -> Bool) async {
    for _ in 0..<100 {
        if condition() { return }
        try? await Task.sleep(for: .milliseconds(2))
    }
}

private enum ReadAloudTestError: Error {
    case cannotCreatePDF
    case networkUnavailable
}

extension ReadAloudTestError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .cannotCreatePDF: return "Cannot create PDF."
        case .networkUnavailable: return "The Internet connection appears to be offline."
        }
    }
}

private actor DoubaoSynthesisCounter {
    private(set) var value = 0

    func increment() {
        value += 1
    }
}

private func writeSearchablePDF(_ text: String, to url: URL) throws {
    var mediaBox = CGRect(x: 0, y: 0, width: 300, height: 200)
    guard let context = CGContext(url as CFURL, mediaBox: &mediaBox, nil) else {
        throw ReadAloudTestError.cannotCreatePDF
    }
    context.beginPDFPage(nil)
    let font = CTFontCreateWithName("Helvetica" as CFString, 14, nil)
    let attributed = NSAttributedString(
        string: text,
        attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font]
    )
    let line = CTLineCreateWithAttributedString(attributed)
    context.textPosition = CGPoint(x: 24, y: 120)
    CTLineDraw(line, context)
    context.endPDFPage()
    context.closePDF()
}
