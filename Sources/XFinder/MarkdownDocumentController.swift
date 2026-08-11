import AppKit
import Foundation

enum MarkdownAgentActivity: Equatable {
    case idle
    case active(Date)
}

struct MarkdownWindowRequest: Codable, Hashable {
    let path: String

    init(url: URL) {
        path = url.standardizedFileURL.path
    }

    var url: URL {
        URL(fileURLWithPath: path)
    }
}

enum MarkdownDocumentPhase: Equatable {
    case loading
    case ready
    case failed(String)
}

@MainActor
final class MarkdownDocumentController: ObservableObject {
    @Published private(set) var url: URL
    @Published private(set) var phase: MarkdownDocumentPhase = .loading
    @Published private(set) var source = ""
    @Published private(set) var rendered = MarkdownRenderDocument(blocks: [], wasTruncated: false)
    @Published private(set) var siblings: [MarkdownSiblingFile] = []
    @Published private(set) var searchQuery = ""
    @Published private(set) var searchMatchCount = 0
    @Published private(set) var highlightedBlockIDs: Set<Int> = []
    @Published private(set) var agentActivity = MarkdownAgentActivity.idle
    @Published private(set) var isEditable = false
    @Published private(set) var isDirty = false
    @Published private(set) var isSaving = false
    @Published private(set) var hasExternalConflict = false
    @Published private(set) var statusText = "Loading…"

    var onStatus: ((String, Bool) -> Void)?

    private let limits: MarkdownDocumentLimits
    private var signature: MarkdownFileSignature?
    private var savedSource = ""
    private var loadGeneration = 0
    private var parseGeneration = 0
    private var siblingGeneration = 0
    private var parseTask: Task<Void, Never>?
    private var autosaveTask: Task<Void, Never>?
    private var highlightClearTask: Task<Void, Never>?
    private var activityClearTask: Task<Void, Never>?

    init(url: URL, limits: MarkdownDocumentLimits = .standard) {
        self.url = url.standardizedFileURL
        self.limits = limits
    }

    deinit {
        parseTask?.cancel()
        autosaveTask?.cancel()
        highlightClearTask?.cancel()
        activityClearTask?.cancel()
    }

    func load(discardingChanges: Bool = false) async {
        guard discardingChanges || !isDirty else { return }
        cancelPendingWork()
        loadGeneration += 1
        let generation = loadGeneration
        phase = .loading
        statusText = "Loading…"
        hasExternalConflict = false
        highlightedBlockIDs = []
        agentActivity = .idle
        await refreshSiblings()

        do {
            let snapshot = try await MarkdownFileService.load(from: url, limits: limits)
            try Task.checkCancellation()
            guard generation == loadGeneration else { return }
            source = snapshot.source
            savedSource = snapshot.source
            signature = snapshot.signature
            isEditable = snapshot.isEditable
            isDirty = false
            updateSearchQuery(searchQuery)
            statusText = snapshot.isEditable ? "Saved" : "Read-only · file exceeds the editing limit"
            phase = .ready
            scheduleParse(delay: nil)
        } catch is CancellationError {
            return
        } catch {
            guard generation == loadGeneration else { return }
            let message = error.localizedDescription
            phase = .failed(message)
            statusText = message
            onStatus?(message, true)
        }
    }

    @discardableResult
    func openSibling(_ sibling: MarkdownSiblingFile, discardingChanges: Bool = false) async -> Bool {
        guard discardingChanges || !isDirty else { return false }
        guard sibling.url.standardizedFileURL != url else { return true }
        url = sibling.url.standardizedFileURL
        await load(discardingChanges: true)
        return true
    }

    func updateSource(_ newValue: String) {
        guard isEditable, source != newValue else { return }
        source = newValue
        isDirty = newValue != savedSource
        hasExternalConflict = false
        highlightedBlockIDs = []
        updateSearchQuery(searchQuery)
        statusText = isDirty ? "Edited" : "Saved"
        scheduleParse(delay: .milliseconds(250))
        scheduleAutosave()
    }

    func updateSearchQuery(_ query: String) {
        searchQuery = query
        searchMatchCount = MarkdownSearchLogic.matchCount(in: source, query: query)
    }

    func toggleTask(ordinal: Int) {
        guard isEditable, let updated = MarkdownTaskListLogic.toggleTask(ordinal: ordinal, in: source) else { return }
        updateSource(updated)
    }

    @discardableResult
    func save(force: Bool = false) async -> Bool {
        guard isEditable, isDirty, let signature else { return !isDirty }
        autosaveTask?.cancel()
        autosaveTask = nil
        let sourceToSave = source
        isSaving = true
        statusText = "Saving…"

        do {
            let newSignature = try await MarkdownFileService.save(
                source: sourceToSave,
                to: url,
                expectedSignature: signature,
                force: force
            )
            self.signature = newSignature
            savedSource = sourceToSave
            isDirty = source != sourceToSave
            hasExternalConflict = false
            updateSearchQuery(searchQuery)
            isSaving = false
            statusText = isDirty ? "Edited" : "Saved"
            onStatus?("Saved \(url.lastPathComponent)", false)
            if isDirty { scheduleAutosave() }
            return true
        } catch MarkdownDocumentError.changedExternally {
            isSaving = false
            hasExternalConflict = true
            statusText = "Changed externally"
            onStatus?("\(url.lastPathComponent) changed externally; save was paused.", true)
            return false
        } catch {
            isSaving = false
            statusText = "Save failed"
            onStatus?("Could not save \(url.lastPathComponent): \(error.localizedDescription)", true)
            return false
        }
    }

    func reloadDiscardingChanges() {
        Task { await load(discardingChanges: true) }
    }

    func overwriteExternalChanges() {
        Task { _ = await save(force: true) }
    }

    func cancelConflictPrompt() {
        hasExternalConflict = false
    }

    func refreshSiblings() async {
        siblingGeneration += 1
        let generation = siblingGeneration
        let currentURL = url
        let limits = limits
        let files = await MarkdownFileService.siblingFiles(for: currentURL, limits: limits)
        guard generation == siblingGeneration, currentURL == url else { return }
        siblings = files
    }

    func handleExternalChange() async {
        await refreshSiblings()
        guard !isDirty, let oldSignature = signature else { return }
        do {
            let snapshot = try await MarkdownFileService.load(from: url, limits: limits)
            guard snapshot.signature != oldSignature else { return }
            let previousDocument = rendered
            source = snapshot.source
            savedSource = snapshot.source
            signature = snapshot.signature
            isEditable = snapshot.isEditable
            isDirty = false
            hasExternalConflict = false
            updateSearchQuery(searchQuery)
            statusText = snapshot.isEditable ? "Synced external changes" : "Read-only · file exceeds the editing limit"
            markAgentActivity()
            let newDocument = MarkdownDocumentParsing.parse(snapshot.source, limits: limits)
            rendered = newDocument
            highlightedBlockIDs = MarkdownDiffLogic.changedBlockIDs(previous: previousDocument, current: newDocument)
            scheduleHighlightClear()
            onStatus?("Synced \(url.lastPathComponent)", false)
        } catch {
            statusText = "External sync failed"
            onStatus?("Could not sync \(url.lastPathComponent): \(error.localizedDescription)", true)
        }
    }

    @discardableResult
    func copyRichTextToPasteboard() -> Bool {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let wrotePlainText = pasteboard.setString(MarkdownExportLogic.plainText(from: rendered), forType: .string)
        let wroteHTML = pasteboard.setString(MarkdownExportLogic.html(from: rendered), forType: .html)
        return wrotePlainText || wroteHTML
    }

    func exportPDF(to destination: URL) throws {
        try MarkdownPDFExporter.write(document: rendered, title: url.lastPathComponent, to: destination)
        onStatus?("Exported PDF to \(destination.lastPathComponent)", false)
    }

    func insertCheatsheet() {
        insertSnippet(MarkdownSnippetLibrary.cheatsheet)
    }

    func insertTemplate(_ template: MarkdownTemplate) {
        insertSnippet(template.source)
    }

    private func insertSnippet(_ snippet: String) {
        guard isEditable else { return }
        let separator = source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : "\n\n"
        updateSource(source + separator + snippet)
    }

    private func scheduleParse(delay: Duration?) {
        parseGeneration += 1
        let generation = parseGeneration
        parseTask?.cancel()
        let sourceToParse = source
        let limits = limits
        parseTask = Task { [weak self] in
            if let delay {
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled else { return }
            }
            let document = await Task.detached(priority: .userInitiated) {
                MarkdownDocumentParsing.parse(sourceToParse, limits: limits)
            }.value
            guard !Task.isCancelled, let self, generation == self.parseGeneration else { return }
            self.rendered = document
            self.highlightedBlockIDs = []
            self.parseTask = nil
        }
    }

    private func scheduleAutosave() {
        autosaveTask?.cancel()
        guard isDirty, !hasExternalConflict else { return }
        autosaveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, let self else { return }
            _ = await self.save()
        }
    }

    private func cancelPendingWork() {
        loadGeneration += 1
        parseGeneration += 1
        siblingGeneration += 1
        parseTask?.cancel()
        parseTask = nil
        autosaveTask?.cancel()
        autosaveTask = nil
        highlightClearTask?.cancel()
        highlightClearTask = nil
        activityClearTask?.cancel()
        activityClearTask = nil
    }

    private func scheduleHighlightClear() {
        highlightClearTask?.cancel()
        highlightClearTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled, let self else { return }
            self.highlightedBlockIDs = []
            self.highlightClearTask = nil
        }
    }

    private func markAgentActivity() {
        agentActivity = .active(Date())
        activityClearTask?.cancel()
        activityClearTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled, let self else { return }
            self.agentActivity = .idle
            self.activityClearTask = nil
        }
    }
}

enum MarkdownTemplate: String, CaseIterable, Identifiable {
    case note
    case meeting
    case research

    var id: String { rawValue }

    var title: String {
        switch self {
        case .note: return "Note"
        case .meeting: return "Meeting"
        case .research: return "Research"
        }
    }

    var source: String {
        switch self {
        case .note:
            return """
                # Note

                ## Summary

                ## Details

                ## Next Actions
                - [ ]
                """
        case .meeting:
            return """
                # Meeting Notes

                ## Decisions
                -

                ## Action Items
                - [ ]

                ## Discussion
                """
        case .research:
            return """
                # Research Brief

                ## Question

                ## Findings
                -

                ## Sources
                -
                """
        }
    }
}

enum MarkdownSnippetLibrary {
    static let cheatsheet = """
        # Markdown Cheatsheet

        ## Text
        **bold**  *italic*  `code`  ==highlight==

        ## Lists
        - Bullet
        - [ ] Task
        - [x] Done

        ## Table
        | Name | Value |
        | --- | --- |
        | Example | 1 |

        ## Code
        ```swift
        let value = 1
        ```
        """
}

enum MarkdownPDFExporter {
    @MainActor
    static func write(document: MarkdownRenderDocument, title: String, to url: URL) throws {
        let plainText = MarkdownExportLogic.plainText(from: document)
        let content = title + "\n\n" + plainText
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
            .foregroundColor: NSColor.textColor,
        ]
        let attributed = NSAttributedString(string: content, attributes: attributes)
        let width: CGFloat = 612
        let horizontalPadding: CGFloat = 48
        let verticalPadding: CGFloat = 48
        let textWidth = width - horizontalPadding * 2
        let boundingHeight = max(
            CGFloat(792),
            attributed.boundingRect(
                with: NSSize(width: textWidth, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading]
            ).height + verticalPadding * 2 + 40
        )
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: width, height: boundingHeight))
        view.isEditable = false
        view.isSelectable = false
        view.textContainerInset = NSSize(width: horizontalPadding, height: verticalPadding)
        view.textContainer?.containerSize = NSSize(width: textWidth, height: .greatestFiniteMagnitude)
        view.textContainer?.widthTracksTextView = false
        view.textStorage?.setAttributedString(attributed)
        let data = view.dataWithPDF(inside: view.bounds)
        try data.write(to: url, options: .atomic)
    }
}
