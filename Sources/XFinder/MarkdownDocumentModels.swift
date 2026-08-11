import Foundation
import Markdown

struct MarkdownDocumentLimits: Equatable, Sendable {
    var maximumFileBytes = 2 * 1_024 * 1_024
    var maximumEditableBytes = 1 * 1_024 * 1_024
    var maximumPreviewCharacters = 250_000
    var maximumBlocks = 2_000
    var maximumSiblingFiles = 300
    var maximumTableRows = 200
    var maximumNestingDepth = 12

    static let standard = MarkdownDocumentLimits()
}

struct MarkdownFileSignature: Equatable, Sendable {
    let size: Int
    let modificationDate: Date?
    let contentFingerprint: UInt64
}

struct MarkdownFileSnapshot: Equatable, Sendable {
    let url: URL
    let source: String
    let signature: MarkdownFileSignature
    let isEditable: Bool
}

struct MarkdownSiblingFile: Identifiable, Equatable, Sendable {
    let url: URL
    let name: String

    var id: String { url.standardizedFileURL.path }
}

enum MarkdownDocumentError: Error, Equatable, LocalizedError {
    case unsupportedFile
    case fileTooLarge(maximumBytes: Int)
    case cannotDecodeUTF8
    case changedExternally
    case cannotRead

    var errorDescription: String? {
        switch self {
        case .unsupportedFile:
            return "Only Markdown files can be opened in the Markdown reader."
        case .fileTooLarge(let maximumBytes):
            return "The Markdown file exceeds the \(maximumBytes / 1_024 / 1_024) MB reading limit."
        case .cannotDecodeUTF8:
            return "The Markdown file is not valid UTF-8 text."
        case .changedExternally:
            return "The file changed on disk after it was opened."
        case .cannotRead:
            return "The Markdown file could not be read."
        }
    }
}

enum MarkdownFileService {
    static let markdownExtensions: Set<String> = ["md", "markdown", "mdown", "mkd"]

    static func isMarkdownURL(_ url: URL) -> Bool {
        markdownExtensions.contains(url.pathExtension.lowercased())
    }

    static func load(
        from url: URL,
        limits: MarkdownDocumentLimits = .standard
    ) async throws -> MarkdownFileSnapshot {
        try await Task.detached(priority: .userInitiated) {
            try loadSynchronously(from: url, limits: limits)
        }.value
    }

    static func loadSynchronously(
        from url: URL,
        limits: MarkdownDocumentLimits = .standard
    ) throws -> MarkdownFileSnapshot {
        guard isMarkdownURL(url) else { throw MarkdownDocumentError.unsupportedFile }
        let metadata = try fileMetadata(for: url)
        guard metadata.size <= limits.maximumFileBytes else {
            throw MarkdownDocumentError.fileTooLarge(maximumBytes: limits.maximumFileBytes)
        }

        let data = try readBoundedData(from: url, maximumBytes: limits.maximumFileBytes)
        guard !data.prefix(4_096).contains(0) else { throw MarkdownDocumentError.cannotDecodeUTF8 }
        let withoutBOM = data.starts(with: [0xEF, 0xBB, 0xBF]) ? data.dropFirst(3) : data[...]
        guard let source = String(data: withoutBOM, encoding: .utf8) else {
            throw MarkdownDocumentError.cannotDecodeUTF8
        }
        let refreshedMetadata = try fileMetadata(for: url)
        let signature = MarkdownFileSignature(
            size: data.count,
            modificationDate: refreshedMetadata.modificationDate,
            contentFingerprint: contentFingerprint(for: data)
        )
        return MarkdownFileSnapshot(
            url: url,
            source: source,
            signature: signature,
            isEditable: signature.size <= limits.maximumEditableBytes
        )
    }

    static func save(
        source: String,
        to url: URL,
        expectedSignature: MarkdownFileSignature,
        force: Bool = false
    ) async throws -> MarkdownFileSignature {
        try await Task.detached(priority: .userInitiated) {
            try saveSynchronously(source: source, to: url, expectedSignature: expectedSignature, force: force)
        }.value
    }

    static func saveSynchronously(
        source: String,
        to url: URL,
        expectedSignature: MarkdownFileSignature,
        force: Bool = false
    ) throws -> MarkdownFileSignature {
        guard isMarkdownURL(url) else { throw MarkdownDocumentError.unsupportedFile }
        if !force, try diskFileMatches(url, expectedSignature: expectedSignature) == false {
            throw MarkdownDocumentError.changedExternally
        }
        let data = Data(source.utf8)
        try data.write(to: url, options: .atomic)
        let metadata = try fileMetadata(for: url)
        return MarkdownFileSignature(
            size: data.count,
            modificationDate: metadata.modificationDate,
            contentFingerprint: contentFingerprint(for: data)
        )
    }

    static func siblingFiles(
        for url: URL,
        limits: MarkdownDocumentLimits = .standard
    ) async -> [MarkdownSiblingFile] {
        await Task.detached(priority: .utility) {
            siblingFilesSynchronously(for: url, limits: limits)
        }.value
    }

    static func siblingFilesSynchronously(
        for url: URL,
        limits: MarkdownDocumentLimits = .standard
    ) -> [MarkdownSiblingFile] {
        let directory = url.deletingLastPathComponent()
        guard
            let urls = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey, .isHiddenKey],
                options: []
            )
        else { return [] }

        return urls.compactMap { itemURL in
            guard isMarkdownURL(itemURL) else { return nil }
            let values = try? itemURL.resourceValues(forKeys: [.isRegularFileKey, .isHiddenKey])
            guard values?.isRegularFile == true, values?.isHidden != true else { return nil }
            return MarkdownSiblingFile(url: itemURL.standardizedFileURL, name: itemURL.lastPathComponent)
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        .prefix(limits.maximumSiblingFiles)
        .map { $0 }
    }

    private static func diskFileMatches(
        _ url: URL,
        expectedSignature: MarkdownFileSignature
    ) throws -> Bool {
        let metadata = try fileMetadata(for: url)
        guard metadata.size == expectedSignature.size,
            metadata.modificationDate == expectedSignature.modificationDate
        else { return false }
        let data = try readBoundedData(from: url, maximumBytes: expectedSignature.size)
        return data.count == expectedSignature.size
            && contentFingerprint(for: data) == expectedSignature.contentFingerprint
    }

    private static func fileMetadata(for url: URL) throws -> (size: Int, modificationDate: Date?) {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
            let size = (attributes[.size] as? NSNumber)?.intValue
        else { throw MarkdownDocumentError.cannotRead }
        return (size, attributes[.modificationDate] as? Date)
    }

    private static func readBoundedData(from url: URL, maximumBytes: Int) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: maximumBytes + 1) ?? Data()
        guard data.count <= maximumBytes else {
            throw MarkdownDocumentError.fileTooLarge(maximumBytes: maximumBytes)
        }
        return data
    }

    private static func contentFingerprint(for data: Data) -> UInt64 {
        data.reduce(14_695_981_039_346_656_037) { hash, byte in
            (hash ^ UInt64(byte)) &* 1_099_511_628_211
        }
    }
}

struct MarkdownInlineStyles: OptionSet, Equatable, Sendable {
    let rawValue: Int

    static let emphasis = MarkdownInlineStyles(rawValue: 1 << 0)
    static let strong = MarkdownInlineStyles(rawValue: 1 << 1)
    static let code = MarkdownInlineStyles(rawValue: 1 << 2)
    static let strikethrough = MarkdownInlineStyles(rawValue: 1 << 3)
    static let highlight = MarkdownInlineStyles(rawValue: 1 << 4)
}

struct MarkdownInlineRun: Equatable, Sendable {
    let text: String
    let styles: MarkdownInlineStyles
    let destination: String?
}

struct MarkdownListItemModel: Equatable, Sendable {
    let checkbox: Bool?
    let taskOrdinal: Int?
    let blocks: [MarkdownBlockModel]
}

struct MarkdownTableModel: Equatable, Sendable {
    enum Alignment: Equatable, Sendable {
        case leading
        case center
        case trailing
    }

    let alignments: [Alignment]
    let header: [[MarkdownInlineRun]]
    let rows: [[[MarkdownInlineRun]]]
}

struct MarkdownImageModel: Equatable, Sendable {
    let source: String
    let altText: String
    let title: String?
}

struct MarkdownBlockModel: Identifiable, Equatable, Sendable {
    indirect enum Kind: Equatable, Sendable {
        case heading(level: Int, runs: [MarkdownInlineRun])
        case paragraph([MarkdownInlineRun])
        case blockQuote([MarkdownBlockModel])
        case code(language: String?, text: String)
        case unorderedList([MarkdownListItemModel])
        case orderedList(start: Int, items: [MarkdownListItemModel])
        case thematicBreak
        case table(MarkdownTableModel)
        case image(MarkdownImageModel)
    }

    let id: Int
    let kind: Kind
}

struct MarkdownRenderDocument: Equatable, Sendable {
    let blocks: [MarkdownBlockModel]
    let wasTruncated: Bool
}

enum MarkdownSearchLogic {
    static func matchCount(in source: String, query: String) -> Int {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedQuery.isEmpty else { return 0 }
        let lowerSource = source.lowercased()
        let lowerQuery = normalizedQuery.lowercased()
        var count = 0
        var searchStart = lowerSource.startIndex
        while let range = lowerSource.range(of: lowerQuery, range: searchStart..<lowerSource.endIndex) {
            count += 1
            searchStart = lowerSource.index(after: range.lowerBound)
        }
        return count
    }
}

enum MarkdownTaskListLogic {
    static func toggleTask(ordinal targetOrdinal: Int, in source: String) -> String? {
        var ordinal = 0
        var lines = source.components(separatedBy: "\n")
        for index in lines.indices {
            guard let markerRange = taskMarkerRange(in: lines[index]) else { continue }
            if ordinal == targetOrdinal {
                let current = lines[index][markerRange]
                lines[index].replaceSubrange(markerRange, with: current.lowercased() == "x" ? " " : "x")
                return lines.joined(separator: "\n")
            }
            ordinal += 1
        }
        return nil
    }

    private static func taskMarkerRange(in line: String) -> Range<String.Index>? {
        guard let open = line.range(of: "[")?.upperBound else { return nil }
        guard open < line.endIndex else { return nil }
        let close = line.index(after: open)
        guard close < line.endIndex, line[close] == "]" else { return nil }
        let marker = line[open]
        guard marker == " " || marker == "x" || marker == "X" else { return nil }
        let prefix = line[..<line.index(before: open)]
        guard prefix.range(of: #"^\s*(?:[-*+]|\d+\.)\s+$"#, options: .regularExpression) != nil else {
            return nil
        }
        return open..<close
    }
}

enum MarkdownDiffLogic {
    static func changedBlockIDs(previous: MarkdownRenderDocument, current: MarkdownRenderDocument) -> Set<Int> {
        let previousTexts = previous.blocks.map(blockText)
        var changed: Set<Int> = []
        for (index, block) in current.blocks.enumerated() {
            guard previousTexts.indices.contains(index), previousTexts[index] == blockText(block) else {
                changed.insert(block.id)
                continue
            }
        }
        return changed
    }

    static func blockText(_ block: MarkdownBlockModel) -> String {
        switch block.kind {
        case .heading(_, let runs), .paragraph(let runs):
            return runs.map(\.text).joined()
        case .blockQuote(let blocks):
            return blocks.map(blockText).joined(separator: "\n")
        case .code(_, let text):
            return text
        case .unorderedList(let items):
            return items.map(listItemText).joined(separator: "\n")
        case .orderedList(_, let items):
            return items.map(listItemText).joined(separator: "\n")
        case .thematicBreak:
            return "---"
        case .table(let table):
            return ([table.header] + table.rows).map { row in
                row.map { $0.map(\.text).joined() }.joined(separator: "\t")
            }.joined(separator: "\n")
        case .image(let image):
            return [image.altText, image.source, image.title ?? ""].joined(separator: " ")
        }
    }

    private static func listItemText(_ item: MarkdownListItemModel) -> String {
        let checkbox = item.checkbox.map { $0 ? "[x]" : "[ ]" } ?? ""
        return checkbox + item.blocks.map(blockText).joined(separator: "\n")
    }
}

enum MarkdownExportLogic {
    static func plainText(from document: MarkdownRenderDocument) -> String {
        document.blocks.map(MarkdownDiffLogic.blockText).joined(separator: "\n\n")
    }

    static func html(from document: MarkdownRenderDocument) -> String {
        document.blocks.map(htmlBlock).joined(separator: "\n")
    }

    private static func htmlBlock(_ block: MarkdownBlockModel) -> String {
        switch block.kind {
        case .heading(let level, let runs):
            return "<h\(level)>\(htmlRuns(runs))</h\(level)>"
        case .paragraph(let runs):
            return "<p>\(htmlRuns(runs))</p>"
        case .blockQuote(let blocks):
            return "<blockquote>\(blocks.map(htmlBlock).joined())</blockquote>"
        case .code(let language, let text):
            let escaped = escapeHTML(text)
            let className = language.map { #" class="language-\#(escapeHTML($0))""# } ?? ""
            return "<pre><code\(className)>\(escaped)</code></pre>"
        case .unorderedList(let items):
            return "<ul>\(items.map(htmlListItem).joined())</ul>"
        case .orderedList(let start, let items):
            return #"<ol start="\#(start)">\#(items.map(htmlListItem).joined())</ol>"#
        case .thematicBreak:
            return "<hr>"
        case .table(let table):
            let header = "<tr>" + table.header.map { "<th>\(htmlRuns($0))</th>" }.joined() + "</tr>"
            let rows = table.rows.map { row in
                "<tr>" + row.map { "<td>\(htmlRuns($0))</td>" }.joined() + "</tr>"
            }.joined()
            return "<table><thead>\(header)</thead><tbody>\(rows)</tbody></table>"
        case .image(let image):
            return #"<img src="\#(escapeHTML(image.source))" alt="\#(escapeHTML(image.altText))">"#
        }
    }

    private static func htmlListItem(_ item: MarkdownListItemModel) -> String {
        let checkbox =
            item.checkbox.map {
                $0 ? #" <input type="checkbox" checked disabled>"# : #" <input type="checkbox" disabled>"#
            } ?? ""
        return "<li>\(checkbox)\(item.blocks.map(htmlBlock).joined())</li>"
    }

    private static func htmlRuns(_ runs: [MarkdownInlineRun]) -> String {
        runs.map { run in
            var html = escapeHTML(run.text).replacingOccurrences(of: "\n", with: "<br>")
            if run.styles.contains(.code) { html = "<code>\(html)</code>" }
            if run.styles.contains(.highlight) { html = "<mark>\(html)</mark>" }
            if run.styles.contains(.strikethrough) { html = "<del>\(html)</del>" }
            if run.styles.contains(.emphasis) { html = "<em>\(html)</em>" }
            if run.styles.contains(.strong) { html = "<strong>\(html)</strong>" }
            if let destination = run.destination {
                html = #"<a href="\#(escapeHTML(destination))">\#(html)</a>"#
            }
            return html
        }.joined()
    }

    private static func escapeHTML(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}

enum MarkdownDocumentParsing {
    static func parse(
        _ source: String,
        limits: MarkdownDocumentLimits = .standard
    ) -> MarkdownRenderDocument {
        guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return MarkdownRenderDocument(blocks: [], wasTruncated: false)
        }
        let wasCharacterLimited = source.count > limits.maximumPreviewCharacters
        let boundedSource = String(source.prefix(limits.maximumPreviewCharacters))
        let document = Document(parsing: boundedSource, options: [.disableSourcePosOpts])
        var builder = MarkdownRenderModelBuilder(limits: limits)
        let blocks = builder.blocks(from: document, depth: 0)
        return MarkdownRenderDocument(blocks: blocks, wasTruncated: wasCharacterLimited || builder.wasTruncated)
    }
}

private struct MarkdownRenderModelBuilder {
    let limits: MarkdownDocumentLimits
    private(set) var wasTruncated = false
    private var nextID = 0
    private var blockCount = 0
    private var nextTaskOrdinal = 0

    init(limits: MarkdownDocumentLimits) {
        self.limits = limits
    }

    mutating func blocks(from markup: Markup, depth: Int) -> [MarkdownBlockModel] {
        guard depth <= limits.maximumNestingDepth else {
            wasTruncated = true
            return []
        }

        var result: [MarkdownBlockModel] = []
        for child in markup.children {
            guard blockCount < limits.maximumBlocks else {
                wasTruncated = true
                break
            }
            if let block = block(from: child, depth: depth) {
                result.append(block)
            }
        }
        return result
    }

    private mutating func block(from markup: Markup, depth: Int) -> MarkdownBlockModel? {
        if let heading = markup as? Heading {
            return makeBlock(.heading(level: heading.level, runs: inlineRuns(from: heading)))
        }
        if let paragraph = markup as? Paragraph {
            let children = Array(paragraph.children)
            if children.count == 1, let image = children.first as? Markdown.Image,
                let source = image.source, !source.isEmpty
            {
                return makeBlock(
                    .image(
                        MarkdownImageModel(source: source, altText: image.plainText, title: image.title)
                    )
                )
            }
            return makeBlock(.paragraph(inlineRuns(from: paragraph)))
        }
        if let quote = markup as? BlockQuote {
            return makeBlock(.blockQuote(blocks(from: quote, depth: depth + 1)))
        }
        if let code = markup as? CodeBlock {
            return makeBlock(.code(language: code.language, text: code.code))
        }
        if let list = markup as? UnorderedList {
            return makeBlock(.unorderedList(listItems(from: list.listItems, depth: depth + 1)))
        }
        if let list = markup as? OrderedList {
            return makeBlock(
                .orderedList(start: Int(list.startIndex), items: listItems(from: list.listItems, depth: depth + 1))
            )
        }
        if markup is ThematicBreak {
            return makeBlock(.thematicBreak)
        }
        if let table = markup as? Table {
            return makeBlock(.table(tableModel(from: table)))
        }
        if let html = markup as? HTMLBlock {
            return makeBlock(.code(language: "html", text: html.rawHTML))
        }

        let nested = blocks(from: markup, depth: depth + 1)
        if nested.count == 1 { return nested[0] }
        return nested.isEmpty ? nil : makeBlock(.blockQuote(nested))
    }

    private mutating func makeBlock(_ kind: MarkdownBlockModel.Kind) -> MarkdownBlockModel {
        let block = MarkdownBlockModel(id: nextID, kind: kind)
        nextID += 1
        blockCount += 1
        return block
    }

    private mutating func listItems<S: Sequence>(
        from items: S,
        depth: Int
    ) -> [MarkdownListItemModel] where S.Element == ListItem {
        items.map { item in
            let checkbox: Bool?
            switch item.checkbox {
            case .checked: checkbox = true
            case .unchecked: checkbox = false
            case nil: checkbox = nil
            }
            let taskOrdinal: Int?
            if checkbox == nil {
                taskOrdinal = nil
            } else {
                taskOrdinal = nextTaskOrdinal
                nextTaskOrdinal += 1
            }
            return MarkdownListItemModel(
                checkbox: checkbox, taskOrdinal: taskOrdinal, blocks: blocks(from: item, depth: depth))
        }
    }

    private mutating func tableModel(from table: Table) -> MarkdownTableModel {
        let maximumColumns = min(table.maxColumnCount, 12)
        if table.maxColumnCount > maximumColumns { wasTruncated = true }

        let alignments = table.columnAlignments.prefix(maximumColumns).map { alignment in
            switch alignment {
            case .center: return MarkdownTableModel.Alignment.center
            case .right: return MarkdownTableModel.Alignment.trailing
            case .left, nil: return MarkdownTableModel.Alignment.leading
            }
        }
        let header = table.head.children.prefix(maximumColumns).map { cell in
            inlineRuns(from: cell)
        }
        let allRows = Array(table.body.rows)
        if allRows.count > limits.maximumTableRows { wasTruncated = true }
        let rows = allRows.prefix(limits.maximumTableRows).map { row in
            row.children.prefix(maximumColumns).map { cell in
                inlineRuns(from: cell)
            }
        }
        return MarkdownTableModel(alignments: alignments, header: header, rows: rows)
    }

    private func inlineRuns(
        from markup: Markup,
        styles: MarkdownInlineStyles = [],
        destination: String? = nil
    ) -> [MarkdownInlineRun] {
        if let text = markup as? Markdown.Text {
            return highlightedRuns(from: text.string, styles: styles, destination: destination)
        }
        if let code = markup as? InlineCode {
            return [MarkdownInlineRun(text: code.code, styles: styles.union(.code), destination: destination)]
        }
        if markup is SoftBreak {
            return [MarkdownInlineRun(text: "\n", styles: styles, destination: destination)]
        }
        if markup is LineBreak {
            return [MarkdownInlineRun(text: "\n", styles: styles, destination: destination)]
        }
        if let html = markup as? InlineHTML {
            return [MarkdownInlineRun(text: html.rawHTML, styles: styles.union(.code), destination: destination)]
        }
        if let image = markup as? Markdown.Image {
            let label = image.plainText.isEmpty ? "Image" : image.plainText
            return [MarkdownInlineRun(text: label, styles: styles, destination: image.source ?? destination)]
        }

        var nestedStyles = styles
        if markup is Emphasis { nestedStyles.insert(.emphasis) }
        if markup is Strong { nestedStyles.insert(.strong) }
        if markup is Strikethrough { nestedStyles.insert(.strikethrough) }
        let nestedDestination = (markup as? Link)?.destination ?? destination

        var result: [MarkdownInlineRun] = []
        for child in markup.children {
            for run in inlineRuns(from: child, styles: nestedStyles, destination: nestedDestination) {
                if let last = result.last, last.styles == run.styles, last.destination == run.destination {
                    result[result.count - 1] = MarkdownInlineRun(
                        text: last.text + run.text,
                        styles: last.styles,
                        destination: last.destination
                    )
                } else {
                    result.append(run)
                }
            }
        }
        return result
    }

    private func highlightedRuns(
        from text: String,
        styles: MarkdownInlineStyles,
        destination: String?
    ) -> [MarkdownInlineRun] {
        var runs: [MarkdownInlineRun] = []
        var remainder = text[...]
        while let start = remainder.range(of: "==") {
            if start.lowerBound > remainder.startIndex {
                runs.append(
                    MarkdownInlineRun(
                        text: String(remainder[..<start.lowerBound]),
                        styles: styles,
                        destination: destination
                    )
                )
            }
            let afterStart = start.upperBound
            guard let end = remainder[afterStart...].range(of: "==") else {
                runs.append(
                    MarkdownInlineRun(
                        text: String(remainder[start.lowerBound...]), styles: styles, destination: destination))
                return runs
            }
            let highlighted = remainder[afterStart..<end.lowerBound]
            if !highlighted.isEmpty {
                runs.append(
                    MarkdownInlineRun(
                        text: String(highlighted),
                        styles: styles.union(.highlight),
                        destination: destination
                    )
                )
            }
            remainder = remainder[end.upperBound...]
        }
        if !remainder.isEmpty {
            runs.append(MarkdownInlineRun(text: String(remainder), styles: styles, destination: destination))
        }
        return runs
    }
}
