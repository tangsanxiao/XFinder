import Foundation
import Testing

@testable import XFinder

// MARK: - Keyboard selection stepping

@Test func selectAllVisibleRowsUsesEveryIDAndFirstAnchor() {
    let state = PaneSelectionLogic.selectAll(ids: ["a", "b", "c"])
    #expect(state.selection == ["a", "b", "c"])
    #expect(state.anchor == "a")
}

@Test func selectAllEmptyRowsClearsAnchor() {
    let state = PaneSelectionLogic.selectAll(ids: [])
    #expect(state.selection.isEmpty)
    #expect(state.anchor == nil)
}

@Test func stepTargetReturnsNilForEmptyRows() {
    #expect(PaneSelectionLogic.stepTarget(ids: [], selection: [], anchor: nil, forward: true) == nil)
}

@Test func stepTargetWithoutSelectionPicksFirstOrLast() {
    let ids = ["a", "b", "c"]
    #expect(PaneSelectionLogic.stepTarget(ids: ids, selection: [], anchor: nil, forward: true) == "a")
    #expect(PaneSelectionLogic.stepTarget(ids: ids, selection: [], anchor: nil, forward: false) == "c")
}

@Test func stepTargetMovesFromAnchor() {
    let ids = ["a", "b", "c", "d"]
    #expect(PaneSelectionLogic.stepTarget(ids: ids, selection: ["b"], anchor: "b", forward: true) == "c")
    #expect(PaneSelectionLogic.stepTarget(ids: ids, selection: ["b"], anchor: "b", forward: false) == "a")
}

@Test func stepTargetClampsAtEnds() {
    let ids = ["a", "b"]
    #expect(PaneSelectionLogic.stepTarget(ids: ids, selection: ["b"], anchor: "b", forward: true) == "b")
    #expect(PaneSelectionLogic.stepTarget(ids: ids, selection: ["a"], anchor: "a", forward: false) == "a")
}

@Test func stepTargetWithMultiSelectionUsesExtremeWhenAnchorMissing() {
    let ids = ["a", "b", "c", "d"]
    // Anchor not part of the rows anymore (e.g. filtered away): fall back to
    // the outermost selected row in the step direction.
    #expect(PaneSelectionLogic.stepTarget(ids: ids, selection: ["a", "c"], anchor: nil, forward: true) == "d")
    #expect(PaneSelectionLogic.stepTarget(ids: ids, selection: ["b", "d"], anchor: nil, forward: false) == "a")
}

// MARK: - Filter

private func makeItems(_ names: [String], in root: URL) throws -> [BrowserFileItem] {
    for name in names {
        try "x".write(to: root.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }
    return try FileBrowserService.contents(of: root)
}

@Test func filterMatchesCaseInsensitiveAndTrimsWhitespace() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("XFinderPL-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let items = try makeItems(["Alpha.txt", "beta.md", "Gamma.txt"], in: root)

    #expect(PaneFilterLogic.filter(items, query: "").map(\.name) == ["Alpha.txt", "beta.md", "Gamma.txt"])
    #expect(PaneFilterLogic.filter(items, query: "   ").map(\.name) == ["Alpha.txt", "beta.md", "Gamma.txt"])
    #expect(PaneFilterLogic.filter(items, query: "ALPHA").map(\.name) == ["Alpha.txt"])
    #expect(PaneFilterLogic.filter(items, query: " txt ").map(\.name) == ["Alpha.txt", "Gamma.txt"])
    #expect(PaneFilterLogic.filter(items, query: "zzz").isEmpty)
}

@Test func modifiedSortCanKeepExistingDirectoryOrderStableAcrossRefresh() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("XFinderStableSort-\(UUID().uuidString)", isDirectory: true)
    let alpha = root.appendingPathComponent("Alpha", isDirectory: true)
    let beta = root.appendingPathComponent("Beta", isDirectory: true)
    try FileManager.default.createDirectory(at: alpha, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: beta, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let oldDate = Date(timeIntervalSince1970: 1_000)
    let middleDate = Date(timeIntervalSince1970: 2_000)
    let newDate = Date(timeIntervalSince1970: 3_000)
    try FileManager.default.setAttributes([.modificationDate: middleDate], ofItemAtPath: alpha.path)
    try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: beta.path)

    let initialItems = try FileBrowserService.contents(of: root)
    let stableDates = PaneFileSortLogic.directoryModificationDates(in: [initialItems])

    try FileManager.default.setAttributes([.modificationDate: newDate], ofItemAtPath: beta.path)
    let refreshedItems = try FileBrowserService.contents(of: root)

    let liveOrder = PaneFileSortLogic.sort(refreshedItems, key: .modified, ascending: false).map(\.name)
    let stableOrder = PaneFileSortLogic.sort(
        refreshedItems,
        key: .modified,
        ascending: false,
        stableDirectoryModificationDates: stableDates
    ).map(\.name)

    #expect(liveOrder == ["Beta", "Alpha"])
    #expect(stableOrder == ["Alpha", "Beta"])
}

@Test func sizeSortOrdersFoldersAndFilesInBothDirections() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("XFinderSizeSort-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
        at: root.appendingPathComponent("Folder"), withIntermediateDirectories: true)
    try Data().write(to: root.appendingPathComponent("Empty.txt"))
    try Data(repeating: 1, count: 10).write(to: root.appendingPathComponent("Small.txt"))
    try Data(repeating: 1, count: 100).write(to: root.appendingPathComponent("Large.txt"))
    defer { try? FileManager.default.removeItem(at: root) }

    let items = try FileBrowserService.contents(of: root)
    let ascending = PaneFileSortLogic.sort(items, key: .size, ascending: true).map(\.name)
    let descending = PaneFileSortLogic.sort(items, key: .size, ascending: false).map(\.name)

    #expect(ascending == ["Folder", "Empty.txt", "Small.txt", "Large.txt"])
    #expect(descending == ["Large.txt", "Small.txt", "Empty.txt", "Folder"])
}

@Test func kindSortUsesNameAsAStableTieBreaker() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("XFinderKindSort-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let items = try makeItems(["Zulu.md", "Alpha.md", "Notes.txt"], in: root)
    let markdownKind = try #require(items.first { $0.name == "Alpha.md" }?.typeDescription)
    #expect(items.first { $0.name == "Zulu.md" }?.typeDescription == markdownKind)

    let sorted = PaneFileSortLogic.sort(items, key: .kind, ascending: true)
    let markdownNames = sorted.filter { $0.url.pathExtension == "md" }.map(\.name)
    #expect(markdownNames == ["Alpha.md", "Zulu.md"])
}

@Test func visibleRowsFlattenExpandedFoldersWithStableIDsAndOrdinals() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("XFinderRows-\(UUID().uuidString)", isDirectory: true)
    let folder = root.appendingPathComponent("Folder", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    try "root".write(to: root.appendingPathComponent("Root.txt"), atomically: true, encoding: .utf8)
    try "child".write(to: folder.appendingPathComponent("Child.txt"), atomically: true, encoding: .utf8)

    let rootItems = try FileBrowserService.contents(of: root)
    let folderItem = try #require(rootItems.first { $0.name == "Folder" })
    let childItems = try FileBrowserService.contents(of: folder)

    let rows = PaneVisibleRowLogic.flatten(
        rootItems,
        expandedFolderIDs: [folderItem.id],
        expandedContents: [folderItem.id: childItems],
        canBrowseInline: { $0.canBrowseInline },
        sortAndFilterChildren: { $0 }
    )

    #expect(rows.map(\.file.name) == ["Folder", "Child.txt", "Root.txt"])
    #expect(rows.map(\.depth) == [0, 1, 0])
    #expect(rows.map(\.ordinal) == [0, 1, 2])
    #expect(rows[0].id == "\(folderItem.id)-0")
    #expect(rows[1].id == "\(childItems[0].id)-1")
}
