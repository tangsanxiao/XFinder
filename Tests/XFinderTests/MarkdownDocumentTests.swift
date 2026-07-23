import Foundation
import Testing

@testable import XFinder

@Test func markdownFileDetectionSupportsCommonExtensions() {
    #expect(MarkdownFileService.isMarkdownURL(URL(fileURLWithPath: "/tmp/README.md")))
    #expect(MarkdownFileService.isMarkdownURL(URL(fileURLWithPath: "/tmp/notes.MARKDOWN")))
    #expect(!MarkdownFileService.isMarkdownURL(URL(fileURLWithPath: "/tmp/notes.txt")))
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

private func withTemporaryMarkdownDirectory<T>(_ operation: (URL) throws -> T) throws -> T {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("XFinderMarkdown-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    return try operation(root)
}
