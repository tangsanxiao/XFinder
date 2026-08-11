import Foundation
import Testing

@testable import XFinder

@Test func markdownFileDetectionSupportsCommonExtensions() {
    #expect(MarkdownFileService.isMarkdownURL(URL(fileURLWithPath: "/tmp/README.md")))
    #expect(MarkdownFileService.isMarkdownURL(URL(fileURLWithPath: "/tmp/notes.MARKDOWN")))
    #expect(MarkdownFileService.isMarkdownURL(URL(fileURLWithPath: "/tmp/draft.mdown")))
    #expect(MarkdownFileService.isMarkdownURL(URL(fileURLWithPath: "/tmp/task.MKD")))
    #expect(!MarkdownFileService.isMarkdownURL(URL(fileURLWithPath: "/tmp/notes.txt")))
}

@Test func markdownSiblingFilesAreSortedBoundedAndMarkdownOnly() throws {
    try withTemporaryMarkdownDirectory { root in
        try "B".write(to: root.appendingPathComponent("b.md"), atomically: true, encoding: .utf8)
        try "A".write(to: root.appendingPathComponent("a.markdown"), atomically: true, encoding: .utf8)
        try "C".write(to: root.appendingPathComponent("c.mdown"), atomically: true, encoding: .utf8)
        try "Hidden".write(to: root.appendingPathComponent(".hidden.md"), atomically: true, encoding: .utf8)
        try "Text".write(to: root.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
        var limits = MarkdownDocumentLimits.standard
        limits.maximumSiblingFiles = 2

        let siblings = MarkdownFileService.siblingFilesSynchronously(
            for: root.appendingPathComponent("b.md"), limits: limits)

        #expect(siblings.map(\.name) == ["a.markdown", "b.md"])
    }
}

@Test func markdownFileLoadingHandlesBOMAndEnforcesBounds() throws {
    try withTemporaryMarkdownDirectory { root in
        let bomURL = root.appendingPathComponent("bom.md")
        try Data([0xEF, 0xBB, 0xBF] + Array("# Title".utf8)).write(to: bomURL)

        let snapshot = try MarkdownFileService.loadSynchronously(from: bomURL)
        #expect(snapshot.source == "# Title")
        #expect(snapshot.isEditable)

        let largeURL = root.appendingPathComponent("large.md")
        try Data(repeating: 65, count: 32).write(to: largeURL)
        var limits = MarkdownDocumentLimits.standard
        limits.maximumFileBytes = 16
        #expect(throws: MarkdownDocumentError.fileTooLarge(maximumBytes: 16)) {
            try MarkdownFileService.loadSynchronously(from: largeURL, limits: limits)
        }
    }
}

@Test func markdownFileLoadingAcceptsEmptyFiles() throws {
    try withTemporaryMarkdownDirectory { root in
        let url = root.appendingPathComponent("empty.md")
        _ = FileManager.default.createFile(atPath: url.path, contents: Data())

        let snapshot = try MarkdownFileService.loadSynchronously(from: url)

        #expect(snapshot.source == "")
        #expect(snapshot.signature.size == 0)
        #expect(snapshot.isEditable)
    }
}

@Test func markdownSaveProtectsExternalChangesAndSupportsExplicitOverwrite() throws {
    try withTemporaryMarkdownDirectory { root in
        let url = root.appendingPathComponent("notes.md")
        try "first".write(to: url, atomically: true, encoding: .utf8)
        let snapshot = try MarkdownFileService.loadSynchronously(from: url)

        try "other".write(to: url, atomically: true, encoding: .utf8)
        if let modificationDate = snapshot.signature.modificationDate {
            try FileManager.default.setAttributes([.modificationDate: modificationDate], ofItemAtPath: url.path)
        }
        #expect(throws: MarkdownDocumentError.changedExternally) {
            try MarkdownFileService.saveSynchronously(
                source: "editor version",
                to: url,
                expectedSignature: snapshot.signature
            )
        }

        _ = try MarkdownFileService.saveSynchronously(
            source: "editor version",
            to: url,
            expectedSignature: snapshot.signature,
            force: true
        )
        #expect(try String(contentsOf: url, encoding: .utf8) == "editor version")
    }
}

@Test func markdownParserHandlesEmptyAndWhitespaceOnlySources() {
    #expect(MarkdownDocumentParsing.parse("").blocks.isEmpty)
    #expect(!MarkdownDocumentParsing.parse("").wasTruncated)
    #expect(MarkdownDocumentParsing.parse(" \n\t\n").blocks.isEmpty)
    #expect(!MarkdownDocumentParsing.parse(" \n\t\n").wasTruncated)
}

@Test func markdownParserBuildsSupportedBlockAndInlineModels() {
    let source = """
        # Heading

        Paragraph with **bold**, *emphasis*, ~~removed~~, `code`, and [link](https://example.com).

        - [x] Complete
        - Plain

        3. Third

        > Quoted text

        | Name | Value |
        | :--- | ---: |
        | CPU | Low |

        ```swift
        let value = 1
        ```

        ![Local image](preview.png "Preview")
        """

    let document = MarkdownDocumentParsing.parse(source)

    #expect(
        document.blocks.contains { block in
            guard case .heading(level: 1, let runs) = block.kind else { return false }
            return runs.map(\.text).joined() == "Heading"
        })
    #expect(
        document.blocks.contains { block in
            guard case .paragraph(let runs) = block.kind else { return false }
            return runs.contains { $0.styles.contains(.strong) }
                && runs.contains { $0.styles.contains(.emphasis) }
                && runs.contains { $0.styles.contains(.strikethrough) }
                && runs.contains { $0.styles.contains(.code) }
                && runs.contains { $0.destination == "https://example.com" }
        })
    #expect(
        document.blocks.contains { block in
            guard case .unorderedList(let items) = block.kind else { return false }
            return items.first?.checkbox == true && items.count == 2
        })
    #expect(
        document.blocks.contains { block in
            guard case .orderedList(start: 3, let items) = block.kind else { return false }
            return items.count == 1
        })
    #expect(
        document.blocks.contains { block in
            guard case .table(let table) = block.kind else { return false }
            return table.header.count == 2 && table.rows.count == 1
                && table.alignments == [.leading, .trailing]
        })
    #expect(
        document.blocks.contains { block in
            guard case .code(language: "swift", let text) = block.kind else { return false }
            return text.contains("let value = 1")
        })
    #expect(
        document.blocks.contains { block in
            guard case .image(let image) = block.kind else { return false }
            return image.source == "preview.png" && image.altText == "Local image" && image.title == "Preview"
        })
}

@Test func markdownParserPreservesSoftBreaksHighlightsAndTaskOrdinals() {
    let document = MarkdownDocumentParsing.parse(
        """
        First line
        second ==marked== line

        - [ ] One
        - [x] Two
        """
    )

    #expect(
        document.blocks.contains { block in
            guard case .paragraph(let runs) = block.kind else { return false }
            return runs.map(\.text).joined().contains("First line\nsecond marked line")
                && runs.contains { $0.text == "marked" && $0.styles.contains(.highlight) }
        })
    #expect(
        document.blocks.contains { block in
            guard case .unorderedList(let items) = block.kind else { return false }
            return items.map(\.taskOrdinal) == [0, 1] && items.map(\.checkbox) == [false, true]
        })
}

@Test func markdownSearchCountsCaseInsensitiveMatches() {
    #expect(MarkdownSearchLogic.matchCount(in: "Alpha alpha ALPHA", query: "alpha") == 3)
    #expect(MarkdownSearchLogic.matchCount(in: "aaaa", query: "aa") == 3)
    #expect(MarkdownSearchLogic.matchCount(in: "No query", query: " ") == 0)
}

@Test func markdownTaskToggleUpdatesTheRequestedTaskOnly() {
    let source = """
        - [ ] One
        - plain
        1. [x] Two
        """

    let updated = MarkdownTaskListLogic.toggleTask(ordinal: 1, in: source)

    #expect(updated == "- [ ] One\n- plain\n1. [ ] Two")
    #expect(MarkdownTaskListLogic.toggleTask(ordinal: 9, in: source) == nil)
}

@Test func markdownDiffAndExportLogicUseRenderedBlocks() {
    let previous = MarkdownDocumentParsing.parse("# Title\n\nOld")
    let current = MarkdownDocumentParsing.parse("# Title\n\nNew ==value==")

    #expect(MarkdownDiffLogic.changedBlockIDs(previous: previous, current: current).count == 1)
    #expect(MarkdownExportLogic.plainText(from: current).contains("New value"))
    #expect(MarkdownExportLogic.html(from: current).contains("<mark>value</mark>"))
}

@Test func markdownParserCapsCharactersAndBlocks() {
    var limits = MarkdownDocumentLimits.standard
    limits.maximumPreviewCharacters = 24
    limits.maximumBlocks = 2
    let document = MarkdownDocumentParsing.parse(
        "# One\n\nTwo\n\nThree\n\nFour with enough trailing text to exceed the limit.",
        limits: limits
    )

    #expect(document.wasTruncated)
    #expect(document.blocks.count <= 2)
}

@MainActor
@Test func markdownControllerLoadsEditsAndSaves() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("XFinderMarkdown-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("controller.md")
    try "# Original".write(to: url, atomically: true, encoding: .utf8)
    let controller = MarkdownDocumentController(url: url)

    await controller.load()
    #expect(controller.phase == .ready)
    #expect(controller.source == "# Original")

    controller.updateSource("# Updated")
    #expect(controller.isDirty)
    #expect(await controller.save())
    #expect(!controller.isDirty)
    #expect(try String(contentsOf: url, encoding: .utf8) == "# Updated")
}

@MainActor
@Test func markdownControllerLoadsEmptyDocument() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("XFinderMarkdown-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("empty.md")
    _ = FileManager.default.createFile(atPath: url.path, contents: Data())
    let controller = MarkdownDocumentController(url: url)

    await controller.load()

    #expect(controller.phase == .ready)
    #expect(controller.source == "")
    #expect(controller.rendered.blocks.isEmpty)
}

@MainActor
@Test func markdownControllerSwitchesSiblingsAndTracksSearch() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("XFinderMarkdown-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let first = root.appendingPathComponent("first.md")
    let second = root.appendingPathComponent("second.md")
    try "Alpha".write(to: first, atomically: true, encoding: .utf8)
    try "Beta beta".write(to: second, atomically: true, encoding: .utf8)
    let controller = MarkdownDocumentController(url: first)

    await controller.load()
    controller.updateSearchQuery("alpha")
    #expect(controller.searchMatchCount == 1)
    #expect(controller.siblings.map(\.name) == ["first.md", "second.md"])

    guard let target = controller.siblings.first(where: { $0.url == second.standardizedFileURL }) else {
        Issue.record("Missing sibling file")
        return
    }
    #expect(await controller.openSibling(target))
    controller.updateSearchQuery("beta")
    #expect(controller.url == second.standardizedFileURL)
    #expect(controller.searchMatchCount == 2)
}

@MainActor
@Test func markdownControllerSyncsExternalChangesWhenClean() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("XFinderMarkdown-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("external.md")
    try "# Title\n\nOld".write(to: url, atomically: true, encoding: .utf8)
    let controller = MarkdownDocumentController(url: url)

    await controller.load()
    try await Task.sleep(for: .milliseconds(50))
    try "# Title\n\nNew".write(to: url, atomically: true, encoding: .utf8)

    await controller.handleExternalChange()

    #expect(controller.source.contains("New"))
    #expect(!controller.highlightedBlockIDs.isEmpty)
    let hasActiveIndicator: Bool
    if case .active = controller.agentActivity {
        hasActiveIndicator = true
    } else {
        hasActiveIndicator = false
    }
    #expect(hasActiveIndicator)
}

@MainActor
@Test func markdownControllerInsertsSnippetsAndExportsPDF() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("XFinderMarkdown-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("export.md")
    let pdfURL = root.appendingPathComponent("export.pdf")
    try "# Export".write(to: url, atomically: true, encoding: .utf8)
    let controller = MarkdownDocumentController(url: url)

    await controller.load()
    controller.insertTemplate(.meeting)
    #expect(controller.source.contains("Meeting Notes"))
    try controller.exportPDF(to: pdfURL)

    let attributes = try FileManager.default.attributesOfItem(atPath: pdfURL.path)
    #expect((attributes[.size] as? NSNumber)?.intValue ?? 0 > 0)
}

private func withTemporaryMarkdownDirectory<T>(_ operation: (URL) throws -> T) throws -> T {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("XFinderMarkdown-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    return try operation(root)
}
