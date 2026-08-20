import Foundation

struct SessionScanSource: Sendable {
    let agent: SessionAgent
    let roots: [URL]
}

private struct SessionCatalogCache: Codable {
    static let currentVersion = 1

    let version: Int
    let entries: [String: SessionCatalogCacheEntry]
}

struct SessionCatalogCacheEntry: Codable, Equatable, Sendable {
    let summary: SessionSummary

    func matches(agent: SessionAgent, url: URL, modified: Date, sizeBytes: Int64) -> Bool {
        summary.agent == agent
            && summary.url.standardizedFileURL == url.standardizedFileURL
            && summary.modified == modified
            && summary.sizeBytes == sizeBytes
    }
}

struct SessionCatalogMetrics: Equatable, Sendable {
    let reusedFileCount: Int
    let parsedFileCount: Int
}

private struct SessionCatalogScanResult: Sendable {
    let summaries: [SessionSummary]
    let metrics: SessionCatalogMetrics
}

/// Shared session metadata catalog for Session Center and Agent Inbox. It
/// coalesces concurrent scans, keeps the result alive when SwiftUI swaps views,
/// and persists bounded list metadata so unchanged JSONL files are not reread
/// after an app relaunch.
actor SessionCatalog {
    private let sources: [SessionScanSource]
    private let cacheURL: URL?
    private var summaries: [SessionSummary]?
    private var scanTask: Task<SessionCatalogScanResult, Never>?
    private var latestMetrics = SessionCatalogMetrics(reusedFileCount: 0, parsedFileCount: 0)

    init(cacheURL: URL?, sources: [SessionScanSource] = SessionScanner.defaultSources) {
        self.cacheURL = cacheURL
        self.sources = sources
    }

    func sessions(force: Bool = false) async -> [SessionSummary] {
        if !force, let summaries {
            return summaries
        }
        if let scanTask {
            return await scanTask.value.summaries
        }

        let sources = sources
        let cacheURL = cacheURL
        let task = Task {
            await SessionScanner.scanWithMetrics(sources: sources, cacheURL: cacheURL)
        }
        scanTask = task
        let result = await task.value
        summaries = result.summaries
        latestMetrics = result.metrics
        scanTask = nil
        return result.summaries
    }

    func metrics() -> SessionCatalogMetrics {
        latestMetrics
    }
}

/// Scans each agent's session stores into a unified catalog. The list pass is
/// cheap (file stat + a short head read for title/project); full transcript
/// parsing happens lazily when a session is opened. Runs off the main actor.
enum SessionScanner {
    static var defaultSources: [SessionScanSource] {
        SessionAgent.allCases.map { SessionScanSource(agent: $0, roots: $0.sessionRoots) }
    }

    static func scan(agents: [SessionAgent] = SessionAgent.allCases) async -> [SessionSummary] {
        let included = Set(agents)
        return await scan(sources: defaultSources.filter { included.contains($0.agent) }, cacheURL: nil)
    }

    static func scan(
        sources: [SessionScanSource],
        cacheURL: URL?,
        codexTitles: [String: String]? = nil
    ) async -> [SessionSummary] {
        await scanWithMetrics(sources: sources, cacheURL: cacheURL, codexTitles: codexTitles).summaries
    }

    fileprivate static func scanWithMetrics(
        sources: [SessionScanSource],
        cacheURL: URL?,
        codexTitles: [String: String]? = nil
    ) async -> SessionCatalogScanResult {
        await Task.detached(priority: .userInitiated) { () -> SessionCatalogScanResult in
            let fileManager = FileManager.default
            let resolvedCodexTitles =
                codexTitles
                ?? (sources.contains { $0.agent == .codex } ? CodexThreadTitleCatalog.load() : [:])
            let cachedEntries = loadCache(at: cacheURL)?.entries ?? [:]
            var currentEntries: [String: SessionCatalogCacheEntry] = [:]
            var summaries: [SessionSummary] = []
            var reusedFileCount = 0
            var parsedFileCount = 0

            for source in sources {
                for root in source.roots {
                    for url in jsonlFiles(in: root, fileManager: fileManager) {
                        guard let metadata = metadata(for: url) else { continue }
                        let key = cacheKey(agent: source.agent, url: url)
                        let resolvedSummary: SessionSummary
                        if let cached = cachedEntries[key],
                            cached.matches(
                                agent: source.agent,
                                url: url,
                                modified: metadata.modified,
                                sizeBytes: metadata.sizeBytes)
                        {
                            resolvedSummary = cached.summary
                            reusedFileCount += 1
                        } else {
                            parsedFileCount += 1
                            guard
                                let parsed = summary(
                                    for: url,
                                    agent: source.agent,
                                    modified: metadata.modified,
                                    sizeBytes: metadata.sizeBytes)
                            else { continue }
                            resolvedSummary = parsed
                        }
                        let titledSummary = applyingCodexTitle(
                            to: resolvedSummary,
                            titles: resolvedCodexTitles)
                        summaries.append(titledSummary)
                        currentEntries[key] = SessionCatalogCacheEntry(summary: titledSummary)
                    }
                }
            }

            if let cacheURL, currentEntries != cachedEntries {
                saveCache(
                    SessionCatalogCache(version: SessionCatalogCache.currentVersion, entries: currentEntries),
                    at: cacheURL)
            }
            // Newest first.
            return SessionCatalogScanResult(
                summaries: summaries.sorted { $0.modified > $1.modified },
                metrics: SessionCatalogMetrics(
                    reusedFileCount: reusedFileCount,
                    parsedFileCount: parsedFileCount
                ))
        }.value
    }

    /// Reads a bounded head/tail sample so selecting a multi-GB transcript
    /// cannot allocate the whole file. Message and character caps apply after
    /// JSONL parsing; the UI marks sampled transcripts as truncated.
    static func transcript(
        for url: URL,
        limits: SessionTranscriptLimits = .standard
    ) async -> SessionTranscript {
        let worker = Task.detached(priority: .userInitiated) { () -> SessionTranscript in
            guard let chunks = transcriptChunks(for: url, limits: limits) else {
                return SessionTranscript(messages: [], exactTokens: 0)
            }
            return parsedTranscript(from: chunks.text, fileWasTruncated: chunks.wasTruncated, limits: limits)
        }
        return await withTaskCancellationHandler {
            await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    private static func transcriptChunks(
        for url: URL,
        limits: SessionTranscriptLimits
    ) -> (text: [String], wasTruncated: Bool)? {
        guard limits.maximumReadBytes > 0,
            limits.maximumMessages > 0,
            limits.maximumCharacters > 0,
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
            let number = attributes[.size] as? NSNumber,
            let handle = try? FileHandle(forReadingFrom: url)
        else { return nil }
        defer { try? handle.close() }

        let fileSize = max(0, number.intValue)
        if fileSize <= limits.maximumReadBytes {
            let data = (try? handle.read(upToCount: limits.maximumReadBytes)) ?? Data()
            return ([String(decoding: data, as: UTF8.self)], false)
        }

        let leadingCount = min(max(1, limits.leadingReadBytes), limits.maximumReadBytes)
        let trailingCount = max(0, limits.maximumReadBytes - leadingCount)
        let leadingData = (try? handle.read(upToCount: leadingCount)) ?? Data()
        var chunks: [String] = []
        if let newline = leadingData.lastIndex(of: 0x0A) {
            chunks.append(String(decoding: leadingData[...newline], as: UTF8.self))
        }

        if trailingCount > 0 {
            let offset = UInt64(max(0, fileSize - trailingCount))
            try? handle.seek(toOffset: offset)
            let trailingData = (try? handle.read(upToCount: trailingCount)) ?? Data()
            if let newline = trailingData.firstIndex(of: 0x0A) {
                let start = trailingData.index(after: newline)
                if start < trailingData.endIndex {
                    chunks.append(String(decoding: trailingData[start...], as: UTF8.self))
                }
            }
        }
        return (chunks, true)
    }

    private static func parsedTranscript(
        from chunks: [String],
        fileWasTruncated: Bool,
        limits: SessionTranscriptLimits
    ) -> SessionTranscript {
        guard !chunks.isEmpty else {
            return SessionTranscript(messages: [], exactTokens: 0, wasTruncated: fileWasTruncated)
        }

        let messageLimitPerChunk = max(1, limits.maximumMessages / chunks.count)
        let characterLimitPerChunk = max(1, limits.maximumCharacters / chunks.count)
        var raw: [SessionMessage] = []
        var contentWasTruncated = false

        for chunk in chunks {
            var chunkMessageCount = 0
            var chunkCharacterCount = 0
            chunk.enumerateLines { line, stop in
                guard !Task.isCancelled else {
                    stop = true
                    return
                }
                guard chunkMessageCount < messageLimitPerChunk,
                    chunkCharacterCount < characterLimitPerChunk
                else {
                    contentWasTruncated = true
                    stop = true
                    return
                }
                guard let message = SessionParsing.message(fromLine: line) else { return }
                let remainingCharacters = characterLimitPerChunk - chunkCharacterCount
                let text = String(message.text.prefix(remainingCharacters))
                if text.count < message.text.count { contentWasTruncated = true }
                raw.append(SessionMessage(id: 0, role: message.role, text: text))
                chunkMessageCount += 1
                chunkCharacterCount += text.count
            }
        }

        let stripped = SessionParsing.stripPreamble(raw).enumerated().map {
            SessionMessage(id: $0.offset, role: $0.element.role, text: $0.element.text)
        }
        let characters = stripped.reduce(0) { $0 + $1.text.count }
        return SessionTranscript(
            messages: stripped,
            exactTokens: SessionParsing.estimateTokens(chars: characters),
            wasTruncated: fileWasTruncated || contentWasTruncated
        )
    }

    /// Recursively collects `*.jsonl` files (sync — the enumerator iterator
    /// isn't available from an async context).
    private static func jsonlFiles(in root: URL, fileManager: FileManager) -> [URL] {
        guard
            let enumerator = fileManager.enumerator(
                at: root, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
                options: [.skipsHiddenFiles])
        else { return [] }
        var result: [URL] = []
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            result.append(url)
        }
        return result
    }

    /// Cheap list metadata: stat for date/size, a bounded head read for the
    /// first human message (title) and the session's cwd (project).
    private static func metadata(for url: URL) -> (modified: Date, sizeBytes: Int64)? {
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let modified = values?.contentModificationDate ?? .distantPast
        let size = Int64(values?.fileSize ?? 0)
        guard size > 0 else { return nil }
        return (modified, size)
    }

    private static func summary(
        for url: URL,
        agent: SessionAgent,
        modified: Date,
        sizeBytes: Int64
    ) -> SessionSummary? {
        var title = ""
        var cwd: String?
        // Read only the first chunk of lines — enough for the meta line and the
        // first real user message — instead of the whole (possibly huge) file.
        if let handle = try? FileHandle(forReadingFrom: url) {
            defer { try? handle.close() }
            // 256KB: enough to get past a large AGENTS.md/attachment preamble
            // to the first real user prompt without reading whole huge files.
            let head = (try? handle.read(upToCount: 256 * 1024)) ?? Data()
            let text = String(decoding: head, as: UTF8.self)
            for line in text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init) {
                if cwd == nil { cwd = SessionParsing.cwd(fromLine: line) }
                if title.isEmpty, let message = SessionParsing.message(fromLine: line),
                    message.role == .user, !SessionParsing.isPreamble(message.text)
                {
                    title = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
                        .replacingOccurrences(of: "\n", with: " ")
                }
                if !title.isEmpty, cwd != nil { break }
            }
        }

        let project = cwd.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "—"
        if title.count > 140 { title = String(title.prefix(140)) + "…" }
        return SessionSummary(
            agent: agent,
            url: url,
            title: title.isEmpty ? url.deletingPathExtension().lastPathComponent : title,
            project: project,
            projectPath: cwd,
            modified: modified,
            sizeBytes: sizeBytes
        )
    }

    private static func cacheKey(agent: SessionAgent, url: URL) -> String {
        "\(agent.rawValue):\(url.standardizedFileURL.path)"
    }

    private static func applyingCodexTitle(
        to summary: SessionSummary,
        titles: [String: String]
    ) -> SessionSummary {
        guard summary.agent == .codex,
            let threadID = CodexThreadTitleCatalog.threadID(fromRolloutURL: summary.url),
            let title = titles[threadID],
            title != summary.title
        else { return summary }
        return SessionSummary(
            agent: summary.agent,
            url: summary.url,
            title: title,
            project: summary.project,
            projectPath: summary.projectPath,
            modified: summary.modified,
            sizeBytes: summary.sizeBytes
        )
    }

    private static func loadCache(at url: URL?) -> SessionCatalogCache? {
        guard let url,
            let data = try? Data(contentsOf: url),
            let cache = try? JSONDecoder().decode(SessionCatalogCache.self, from: data),
            cache.version == SessionCatalogCache.currentVersion
        else { return nil }
        return cache
    }

    private static func saveCache(_ cache: SessionCatalogCache, at url: URL) {
        guard let data = try? JSONEncoder().encode(cache) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}
