import AppKit
import Foundation
import PDFKit

private struct ReadAloudSourceSignature: Equatable, Sendable {
    let path: String
    let fileSize: Int
    let modificationDate: Date?
}

private struct ReadAloudCacheKey: Equatable, Sendable {
    let signature: ReadAloudSourceSignature
    let kind: ReadAloudFileKind
    let limits: ReadAloudLimits
}

private actor ReadAloudDocumentCache {
    private var entry: (key: ReadAloudCacheKey, document: ReadAloudDocument)?

    func document(for key: ReadAloudCacheKey) -> ReadAloudDocument? {
        guard entry?.key == key else { return nil }
        return entry?.document
    }

    func store(_ document: ReadAloudDocument, for key: ReadAloudCacheKey) {
        entry = (key, document)
    }
}

enum ReadableContentService {
    private static let cache = ReadAloudDocumentCache()

    static func load(
        from url: URL,
        kind: ReadAloudFileKind,
        limits: ReadAloudLimits = .standard
    ) async throws -> ReadAloudDocument {
        let signatureTask = Task.detached(priority: .userInitiated) {
            try sourceSignature(at: url)
        }
        let signature = try await withTaskCancellationHandler {
            try await signatureTask.value
        } onCancel: {
            signatureTask.cancel()
        }
        try Task.checkCancellation()
        let cacheKey = ReadAloudCacheKey(signature: signature, kind: kind, limits: limits)
        if let cached = await cache.document(for: cacheKey) {
            return cached
        }

        let task = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let document = try loadSynchronously(from: url, kind: kind, limits: limits)
            try Task.checkCancellation()
            return document
        }
        let document = try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
        try Task.checkCancellation()
        await cache.store(document, for: cacheKey)
        return document
    }

    static func loadSynchronously(
        from url: URL,
        kind: ReadAloudFileKind,
        limits: ReadAloudLimits = .standard
    ) throws -> ReadAloudDocument {
        let size = try fileSize(at: url)
        let maximumBytes = kind == .pdf ? limits.maximumPDFFileBytes : limits.maximumTextFileBytes
        guard size <= maximumBytes else {
            throw ReadAloudError.fileTooLarge(maximumBytes: maximumBytes)
        }

        let extracted: (text: String, truncated: Bool)
        switch kind {
        case .plainText, .markdown:
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            guard let decoded = decodeText(data) else { throw ReadAloudError.cannotDecodeText }
            extracted = boundedText(decoded, maximumCharacters: limits.maximumExtractedCharacters)
        case .html:
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            guard let decoded = decodeText(data) else { throw ReadAloudError.cannotDecodeText }
            extracted = boundedText(decoded, maximumCharacters: limits.maximumExtractedCharacters)
        case .rtf:
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            let attributed = try NSAttributedString(
                data: data,
                options: [.documentType: NSAttributedString.DocumentType.rtf],
                documentAttributes: nil
            )
            extracted = boundedText(attributed.string, maximumCharacters: limits.maximumExtractedCharacters)
        case .pdf:
            extracted = try extractPDFText(from: url, limits: limits)
        }

        try Task.checkCancellation()
        let cleaned = ReadAloudTextLogic.cleanedText(extracted.text, kind: kind)
        let bounded = boundedText(cleaned, maximumCharacters: limits.maximumExtractedCharacters)
        let chunks = ReadAloudTextLogic.chunks(
            from: bounded.text,
            maximumCharacters: limits.maximumChunkCharacters
        )
        guard !chunks.isEmpty else { throw ReadAloudError.noReadableText }

        return ReadAloudDocument(
            url: url,
            chunks: chunks,
            wasTruncated: extracted.truncated || bounded.truncated
        )
    }

    private static func fileSize(at url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.size] as? NSNumber)?.intValue ?? 0
    }

    private static func sourceSignature(at url: URL) throws -> ReadAloudSourceSignature {
        try Task.checkCancellation()
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return ReadAloudSourceSignature(
            path: url.standardizedFileURL.path,
            fileSize: (attributes[.size] as? NSNumber)?.intValue ?? 0,
            modificationDate: attributes[.modificationDate] as? Date
        )
    }

    private static func decodeText(_ data: Data) -> String? {
        guard !data.isEmpty else { return "" }

        if data.starts(with: [0xEF, 0xBB, 0xBF]) {
            return String(data: data.dropFirst(3), encoding: .utf8)
        }
        if data.starts(with: [0xFF, 0xFE]) {
            return String(data: data.dropFirst(2), encoding: .utf16LittleEndian)
        }
        if data.starts(with: [0xFE, 0xFF]) {
            return String(data: data.dropFirst(2), encoding: .utf16BigEndian)
        }
        guard looksLikeText(data) else { return nil }
        return String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1)
    }

    private static func looksLikeText(_ data: Data) -> Bool {
        let sample = data.prefix(4_096)
        guard !sample.isEmpty else { return true }
        var controlBytes = 0
        for byte in sample where byte == 0 || (byte < 0x09) || (byte > 0x0D && byte < 0x20) {
            controlBytes += 1
        }
        return controlBytes * 50 <= sample.count
    }

    private static func boundedText(_ text: String, maximumCharacters: Int) -> (text: String, truncated: Bool) {
        guard text.count > maximumCharacters else { return (text, false) }
        return (String(text.prefix(maximumCharacters)), true)
    }

    private static func extractPDFText(
        from url: URL,
        limits: ReadAloudLimits
    ) throws -> (text: String, truncated: Bool) {
        guard let document = PDFDocument(url: url) else { throw ReadAloudError.unreadablePDF }

        let pageLimit = min(document.pageCount, limits.maximumPDFPages)
        var parts: [String] = []
        parts.reserveCapacity(pageLimit)
        var collectedCharacters = 0
        var truncated = document.pageCount > pageLimit

        for pageIndex in 0..<pageLimit {
            try Task.checkCancellation()
            guard let pageText = document.page(at: pageIndex)?.string, !pageText.isEmpty else { continue }
            let remaining = limits.maximumExtractedCharacters - collectedCharacters
            guard remaining > 0 else {
                truncated = true
                break
            }
            if pageText.count > remaining {
                parts.append(String(pageText.prefix(remaining)))
                collectedCharacters += remaining
                truncated = true
                break
            }
            parts.append(pageText)
            collectedCharacters += pageText.count
        }
        return (parts.joined(separator: "\n\n"), truncated)
    }
}
