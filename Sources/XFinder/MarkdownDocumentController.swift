import Foundation

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
    @Published private(set) var phase: MarkdownDocumentPhase = .loading
    @Published private(set) var source = ""
    @Published private(set) var rendered = MarkdownRenderDocument(blocks: [], wasTruncated: false)
    @Published private(set) var isEditable = false
    @Published private(set) var isDirty = false
    @Published private(set) var isSaving = false
    @Published private(set) var hasExternalConflict = false
    @Published private(set) var statusText = "Loading…"

    let url: URL
    var onStatus: ((String, Bool) -> Void)?

    private let limits: MarkdownDocumentLimits
    private var signature: MarkdownFileSignature?
    private var savedSource = ""
    private var loadGeneration = 0
    private var parseGeneration = 0
    private var parseTask: Task<Void, Never>?
    private var autosaveTask: Task<Void, Never>?

    init(url: URL, limits: MarkdownDocumentLimits = .standard) {
        self.url = url.standardizedFileURL
        self.limits = limits
    }

    deinit {
        parseTask?.cancel()
        autosaveTask?.cancel()
    }

    func load(discardingChanges: Bool = false) async {
        guard discardingChanges || !isDirty else { return }
        cancelPendingWork()
        loadGeneration += 1
        let generation = loadGeneration
        phase = .loading
        statusText = "Loading…"
        hasExternalConflict = false

        do {
            let snapshot = try await MarkdownFileService.load(from: url, limits: limits)
            try Task.checkCancellation()
            guard generation == loadGeneration else { return }
            source = snapshot.source
            savedSource = snapshot.source
            signature = snapshot.signature
            isEditable = snapshot.isEditable
            isDirty = false
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

    func updateSource(_ newValue: String) {
        guard isEditable, source != newValue else { return }
        source = newValue
        isDirty = newValue != savedSource
        hasExternalConflict = false
        statusText = isDirty ? "Edited" : "Saved"
        scheduleParse(delay: .milliseconds(250))
        scheduleAutosave()
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
        parseTask?.cancel()
        parseTask = nil
        autosaveTask?.cancel()
        autosaveTask = nil
    }
}
