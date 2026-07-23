import Foundation

enum ReadAloudFileKind: Equatable, Sendable {
    case plainText
    case markdown
    case html
    case rtf
    case pdf

    private static let extensionlessTextNames: Set<String> = [
        "dockerfile", "gemfile", "license", "makefile", "podfile", "rakefile", "readme",
    ]

    static func detect(url: URL, isDirectory: Bool, isPackage: Bool) -> ReadAloudFileKind? {
        guard !isDirectory, !isPackage else { return nil }

        let extensionName = url.pathExtension.lowercased()
        switch extensionName {
        case "md", "markdown":
            return .markdown
        case "html", "htm":
            return .html
        case "rtf":
            return .rtf
        case "pdf":
            return .pdf
        case "txt", "text", "jsonl":
            return .plainText
        default:
            break
        }

        if FileCategoryClassifier.codeExtensions.contains(extensionName)
            || FileCategoryClassifier.dataExtensions.contains(extensionName)
            || FileCategoryClassifier.logExtensions.contains(extensionName)
        {
            return .plainText
        }

        let lowercasedName = url.lastPathComponent.lowercased()
        if extensionlessTextNames.contains(lowercasedName)
            || (extensionName.isEmpty && lowercasedName.hasPrefix("."))
            || lowercasedName.hasPrefix(".env")
        {
            return .plainText
        }

        return nil
    }

    static func detect(item: BrowserFileItem) -> ReadAloudFileKind? {
        detect(url: item.url, isDirectory: item.isDirectory, isPackage: item.isPackage)
    }
}

struct ReadAloudLimits: Sendable, Equatable {
    var maximumTextFileBytes = 5 * 1_024 * 1_024
    var maximumPDFFileBytes = 25 * 1_024 * 1_024
    var maximumPDFPages = 200
    var maximumExtractedCharacters = 250_000
    var maximumChunkCharacters = 600

    static let standard = ReadAloudLimits()
}

struct ReadAloudDocument: Sendable, Equatable {
    let url: URL
    let chunks: [String]
    let wasTruncated: Bool
}

enum ReadAloudError: Error, Equatable, LocalizedError {
    case unsupportedFile
    case fileTooLarge(maximumBytes: Int)
    case cannotDecodeText
    case unreadablePDF
    case noReadableText

    var errorDescription: String? {
        switch self {
        case .unsupportedFile:
            return "This file type is not supported for reading aloud."
        case .fileTooLarge(let maximumBytes):
            return "The file exceeds the \(maximumBytes / 1_024 / 1_024) MB reading limit."
        case .cannotDecodeText:
            return "The file does not contain decodable text."
        case .unreadablePDF:
            return "The PDF could not be opened."
        case .noReadableText:
            return "No readable text was found."
        }
    }
}

enum ReadAloudSpeed: String, CaseIterable, Identifiable, Sendable {
    case slow
    case normal
    case comfortable
    case fast
    case fastest

    var id: String { rawValue }

    var multiplier: Float {
        switch self {
        case .slow: return 0.75
        case .normal: return 1
        case .comfortable: return 1.25
        case .fast: return 1.5
        case .fastest: return 2
        }
    }

    var title: String {
        switch self {
        case .slow: return "0.75x"
        case .normal: return "1.0x"
        case .comfortable: return "1.25x"
        case .fast: return "1.5x"
        case .fastest: return "2.0x"
        }
    }
}

enum ReadAloudPhase: Equatable, Sendable {
    case idle
    case loading
    case playing
    case paused
}

enum ReadAloudEvent: Equatable, Sendable {
    case preparing(String)
    case started(String, truncated: Bool)
    case completed(String)
    case stopped(String)
    case fallback(String)
    case failed(String)
}

enum ReadAloudTextLogic {
    static func cleanedText(_ text: String, kind: ReadAloudFileKind) -> String {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        switch kind {
        case .markdown:
            return cleanMarkdown(normalized)
        case .html:
            return cleanHTML(normalized)
        case .plainText, .rtf, .pdf:
            return normalizeLines(normalized)
        }
    }

    static func chunks(from text: String, maximumCharacters: Int) -> [String] {
        guard maximumCharacters > 0 else { return [] }

        var result: [String] = []
        var current = ""

        func flushCurrent() {
            let value = current.trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { result.append(value) }
            current = ""
        }

        for rawLine in text.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else {
                flushCurrent()
                continue
            }

            for unit in splitLongUnit(line, maximumCharacters: maximumCharacters) {
                let separatorCount = current.isEmpty ? 0 : 1
                if current.count + separatorCount + unit.count <= maximumCharacters {
                    current += current.isEmpty ? unit : " \(unit)"
                } else {
                    flushCurrent()
                    current = unit
                }
            }
        }
        flushCurrent()
        return result
    }

    static func preferredLanguageCode(for text: String) -> String? {
        var inspected = 0
        var cjkCount = 0
        for scalar in text.unicodeScalars.prefix(4_096) {
            inspected += 1
            switch scalar.value {
            case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF:
                cjkCount += 1
            default:
                break
            }
        }
        guard inspected > 0, cjkCount >= 2, cjkCount * 10 >= inspected else { return nil }
        return "zh-CN"
    }

    private static func cleanMarkdown(_ text: String) -> String {
        let lines = text.components(separatedBy: "\n")
        var output: [String] = []
        var skipsFrontmatter = lines.first?.trimmingCharacters(in: .whitespaces) == "---"

        for (index, rawLine) in lines.enumerated() {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            if skipsFrontmatter {
                if index > 0, line == "---" { skipsFrontmatter = false }
                continue
            }
            if line.hasPrefix("```") || line.hasPrefix("~~~") { continue }

            while line.hasPrefix("#") { line.removeFirst() }
            line = line.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix(">") {
                line.removeFirst()
                line = line.trimmingCharacters(in: .whitespaces)
            }
            if ["- ", "* ", "+ "].contains(where: { line.hasPrefix($0) }) {
                line.removeFirst(2)
            }
            line = strippingOrderedListPrefix(from: line)
            line = replacingMarkdownLinks(in: line)
            line = line.replacingOccurrences(of: "**", with: "")
                .replacingOccurrences(of: "__", with: "")
                .replacingOccurrences(of: "`", with: "")
            output.append(line)
        }
        return normalizeLines(output.joined(separator: "\n"))
    }

    private static func strippingOrderedListPrefix(from line: String) -> String {
        guard let period = line.firstIndex(of: "."), period != line.startIndex else { return line }
        let prefix = line[..<period]
        let afterPeriod = line.index(after: period)
        guard prefix.allSatisfy(\.isNumber), afterPeriod < line.endIndex, line[afterPeriod].isWhitespace else {
            return line
        }
        return String(line[line.index(after: afterPeriod)...])
    }

    private static func replacingMarkdownLinks(in line: String) -> String {
        line.replacingOccurrences(
            of: #"!\[([^\]]*)\]\([^\)]*\)"#,
            with: "$1",
            options: .regularExpression
        ).replacingOccurrences(
            of: #"\[([^\]]+)\]\([^\)]*\)"#,
            with: "$1",
            options: .regularExpression
        )
    }

    private static func cleanHTML(_ text: String) -> String {
        var cleaned = text.replacingOccurrences(
            of: #"(?is)<(script|style)[^>]*>.*?</\1>"#,
            with: " ",
            options: .regularExpression
        )
        cleaned = cleaned.replacingOccurrences(
            of: #"(?i)</?(p|div|br|li|h[1-6]|tr|section|article)[^>]*>"#,
            with: "\n",
            options: .regularExpression
        )
        cleaned = cleaned.replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
        let entities = [
            "&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'",
        ]
        for (entity, replacement) in entities {
            cleaned = cleaned.replacingOccurrences(of: entity, with: replacement)
        }
        return normalizeLines(cleaned)
    }

    private static func normalizeLines(_ text: String) -> String {
        var output: [String] = []
        var previousWasBlank = true
        for rawLine in text.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                if !previousWasBlank { output.append("") }
                previousWasBlank = true
            } else {
                output.append(line)
                previousWasBlank = false
            }
        }
        while output.last == "" { output.removeLast() }
        return output.joined(separator: "\n")
    }

    private static func splitLongUnit(_ text: String, maximumCharacters: Int) -> [String] {
        guard text.count > maximumCharacters else { return [text] }

        var result: [String] = []
        var remaining = text[...]
        while remaining.count > maximumCharacters {
            let hardEnd = remaining.index(remaining.startIndex, offsetBy: maximumCharacters)
            let candidate = remaining[..<hardEnd]
            let minimumBreak =
                candidate.index(
                    candidate.startIndex,
                    offsetBy: max(1, maximumCharacters / 2),
                    limitedBy: candidate.endIndex
                ) ?? candidate.startIndex
            let preferredBreak = candidate.lastIndex { character in
                character.isWhitespace || ".!?。！？；;，,".contains(character)
            }
            let cutIndex = preferredBreak.flatMap { $0 >= minimumBreak ? candidate.index(after: $0) : nil } ?? hardEnd
            let piece = remaining[..<cutIndex].trimmingCharacters(in: .whitespacesAndNewlines)
            if !piece.isEmpty { result.append(piece) }
            remaining = remaining[cutIndex...]
            while remaining.first?.isWhitespace == true { remaining.removeFirst() }
        }
        let tail = remaining.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty { result.append(tail) }
        return result
    }
}
