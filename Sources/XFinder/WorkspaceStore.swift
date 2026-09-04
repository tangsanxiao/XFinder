import AppKit
import Foundation

/// One entry in the in-app trace panel: every status message and error the
/// store emits, timestamped, so debugging doesn't depend on a single
/// transient alert.
struct AppEvent: Identifiable, Equatable {
    let id = UUID()
    let date: Date
    let isError: Bool
    let message: String
}

private enum FileHistoryOperation {
    case remove(URL)
    case move(from: URL, to: URL)
    case copy(from: URL, to: URL)
    case trash(URL)
    case createDirectory(URL)
    case createEmptyFile(URL)
}

private struct FileHistoryEntry {
    let title: String
    let undo: FileHistoryOperation
    let redo: FileHistoryOperation?
}

@MainActor
final class WorkspaceStore: ObservableObject {
    @Published var workspaces: [Workspace] = []
    @Published var selectedWorkspaceID: UUID?
    @Published var statusMessage = "Ready" {
        didSet { recordEvent(statusMessage, isError: false) }
    }
    @Published var lastError: String? {
        // nil assignments are alert dismissals, not events.
        didSet { if let lastError { recordEvent(lastError, isError: true) } }
    }
    /// Newest first, capped — the trace panel's data source.
    @Published private(set) var events: [AppEvent] = []
    @Published private(set) var fileTasks: [FileTask] = []
    @Published private(set) var canUndoFileOperation = false
    @Published private(set) var canRedoFileOperation = false
    @Published var fileOperationRevision = 0
    @Published private var paneLocations: [UUID: String] = [:]
    @Published private var paneSortOrders: [UUID: PaneSortOrder] = [:]
    /// Drives the Settings sheet; toggled from the sidebar gear and the
    /// standard ⌘, menu command. Not persisted.
    @Published var isSettingsPresented = false
    /// When true, the detail area shows the Skill Hub instead of the file
    /// panes. Not persisted.
    /// Which top-level panel the content area shows.
    @Published var activePanel: ActivePanel = .files

    enum ActivePanel { case files, skills, agent, network }

    @Published private(set) var agentInboxProjects: [AgentInboxProject] = []
    @Published private(set) var agentInboxIsRefreshing = false
    @Published private(set) var agentInboxLastUpdated: Date?
    @Published var agentInboxShowsHidden = false
    @Published private(set) var agentInboxExtractingProjectIDs: Set<String> = []
    @Published private(set) var agentInboxPreferences = AgentInboxPreferences() {
        didSet {
            guard agentInboxPreferences != oldValue else { return }
            saveAgentInboxPreferences()
        }
    }
    @Published var sessionCenterRequestedSessionID: SessionSummary.ID?
    @Published var agentInboxRequestedProjectID: AgentInboxProject.ID?

    /// Back-compat shim: the sidebar/Skill Center still read/write this.
    var showsSkillHub: Bool {
        get { activePanel == .skills }
        set { activePanel = newValue ? .skills : .files }
    }
    /// Files currently being dragged inside the app — the whole selection, so a
    /// multi-file drag moves every file (SwiftUI `.onDrag` only carries one
    /// provider). Set at drag start, consumed and cleared on drop.
    @Published var dragPayload: [URL] = []
    @Published var settings = AppSettings() {
        didSet {
            guard settings != oldValue else { return }
            saveSettings()
        }
    }
    @Published var stars: [StarItem] = []
    /// The currently focused pane (nil = a "待添加" placeholder is the target).
    /// Single source of truth so the sidebar and panes never disagree.
    /// Changes are traced into the event log — keyboard input routes by focus,
    /// so "keys acted on the wrong pane" must be diagnosable from the panel.
    @Published var focusedPaneID: UUID? {
        didSet {
            guard focusedPaneID != oldValue else { return }
            recordEvent("Focus → \(paneTitle(for: focusedPaneID))", isError: false)
        }
    }

    private let persistenceURL: URL
    private let starsURL: URL
    private let paneLocationsURL: URL
    private let paneSortOrdersURL: URL
    private let settingsURL: URL
    private let agentInboxPreferencesURL: URL
    let sessionCatalog: SessionCatalog
    private let finderController = FinderController()
    private var runningCompressionProcesses: [UUID: Process] = [:]
    private var undoStack: [FileHistoryEntry] = []
    private var redoStack: [FileHistoryEntry] = []
    private var agentInboxExtractedProjectIDs: Set<String> = []

    /// - Parameter supportDirectory: base directory for persistence. Defaults to
    ///   the real Application Support location; tests pass a temp directory to
    ///   stay isolated and deterministic. Legacy migration runs only for the
    ///   real location.
    init(supportDirectory: URL? = nil) {
        let support =
            supportDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let directory = support.appendingPathComponent("XFinder", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        persistenceURL = directory.appendingPathComponent("workspaces.json")
        starsURL = directory.appendingPathComponent("stars.json")
        paneLocationsURL = directory.appendingPathComponent("pane-locations.json")
        paneSortOrdersURL = directory.appendingPathComponent("pane-sort-orders.json")
        settingsURL = directory.appendingPathComponent("settings.json")
        agentInboxPreferencesURL = directory.appendingPathComponent("agent-inbox-preferences.json")
        sessionCatalog = SessionCatalog(cacheURL: directory.appendingPathComponent("session-catalog.json"))

        if supportDirectory == nil {
            let legacyPersistenceURL =
                support
                .appendingPathComponent("FinderHub", isDirectory: true)
                .appendingPathComponent("workspaces.json")
            if !FileManager.default.fileExists(atPath: persistenceURL.path),
                FileManager.default.fileExists(atPath: legacyPersistenceURL.path)
            {
                try? FileManager.default.copyItem(at: legacyPersistenceURL, to: persistenceURL)
            }
        }
        load()
        loadStars()
        loadPaneLocations()
        loadPaneSortOrders()
        loadSettings()
        loadAgentInboxPreferences()
    }

    private func loadSettings() {
        guard let data = try? Data(contentsOf: settingsURL),
            let decoded = try? JSONDecoder().decode(AppSettings.self, from: data)
        else { return }
        settings = decoded
    }

    private func saveSettings() {
        guard let data = try? JSONEncoder.pretty.encode(settings) else { return }
        try? data.write(to: settingsURL, options: .atomic)
    }

    /// Bilingual string helper: returns the Chinese or English variant per the
    /// language setting (`.system` follows the OS). Views read it as
    /// `store.loc("中文", "English")`; since `settings` is @Published, changing
    /// the language re-renders everything.
    func loc(_ zh: String, _ en: String) -> String {
        settings.language.isChineseResolved ? zh : en
    }

    private func recordEvent(_ message: String, isError: Bool) {
        events.insert(AppEvent(date: Date(), isError: isError, message: message), at: 0)
        if events.count > 200 {
            events.removeLast(events.count - 200)
        }
    }

    func clearEvents() {
        events.removeAll()
    }

    func handleReadAloudEvent(_ event: ReadAloudEvent) {
        switch event {
        case .preparing(let name):
            statusMessage = loc("正在准备朗读 \(name)…", "Preparing to read \(name)…")
        case .started(let name, let truncated):
            statusMessage = loc(
                truncated ? "正在朗读 \(name)（内容已按性能上限截取）" : "正在朗读 \(name)",
                truncated ? "Reading \(name) (content limited for performance)" : "Reading \(name)"
            )
        case .completed(let name):
            statusMessage = loc("已朗读完 \(name)", "Finished reading \(name)")
        case .stopped(let name):
            statusMessage = loc("已停止朗读 \(name)", "Stopped reading \(name)")
        case .fallback(let reason):
            statusMessage = loc(
                "豆包语音不可用，已切换到系统语音：\(reason)",
                "Doubao Speech unavailable; using system voice: \(reason)"
            )
        case .failed(let message):
            lastError = loc("朗读失败：\(message)", "Read Aloud failed: \(message)")
        }
    }

    var agentInboxVisibleProjects: [AgentInboxProject] {
        AgentInboxProjectCatalog.visibleProjects(
            agentInboxProjects,
            preferences: agentInboxPreferences,
            showsHidden: agentInboxShowsHidden
        )
    }

    var agentInboxHiddenCount: Int {
        agentInboxProjects.filter { isAgentInboxProjectHidden($0) }.count
    }

    func ensureAgentInboxLoaded() async {
        guard agentInboxProjects.isEmpty else { return }
        await refreshAgentInbox(force: false)
    }

    func refreshAgentInbox(force: Bool) async {
        guard force || agentInboxProjects.isEmpty else { return }
        guard !agentInboxIsRefreshing else { return }
        agentInboxIsRefreshing = true
        let existingExtractedItems =
            force
            ? [:]
            : Dictionary(uniqueKeysWithValues: agentInboxProjects.map { ($0.id, $0.extractedItems) })

        let sessions = await sessionCatalog.sessions(force: force)
        var loaded = await AgentInboxScanner.scan(workspaces: workspaces, stars: stars, sessions: sessions)
        for index in loaded.indices {
            if let items = existingExtractedItems[loaded[index].id] {
                loaded[index].extractedItems = items
            }
        }
        agentInboxProjects = loaded
        agentInboxLastUpdated = Date()
        agentInboxIsRefreshing = false
        agentInboxExtractedProjectIDs = Set(loaded.filter { !$0.extractedItems.isEmpty }.map(\.id))
        statusMessage = "Agent Inbox refreshed"
    }

    func loadAgentInboxExtractedItems(for project: AgentInboxProject) async {
        let id = project.id
        guard !agentInboxExtractedProjectIDs.contains(id),
            !agentInboxExtractingProjectIDs.contains(id)
        else { return }
        guard agentInboxProjects.contains(where: { $0.id == id }) else { return }

        agentInboxExtractingProjectIDs.insert(id)
        let items = await AgentInboxScanner.extractedItems(from: project.sessions)
        if let index = agentInboxProjects.firstIndex(where: { $0.id == id }) {
            agentInboxProjects[index].extractedItems = Array(items.prefix(8))
        }
        agentInboxExtractedProjectIDs.insert(id)
        agentInboxExtractingProjectIDs.remove(id)
    }

    func isAgentInboxProjectHidden(_ project: AgentInboxProject) -> Bool {
        agentInboxPreferences.hiddenProjectPaths.contains(AgentInboxProjectCatalog.key(for: project))
    }

    func isAgentInboxProjectPinned(_ project: AgentInboxProject) -> Bool {
        agentInboxPreferences.pinnedProjectPaths.contains(AgentInboxProjectCatalog.key(for: project))
    }

    func hideAgentInboxProject(_ project: AgentInboxProject) {
        let key = AgentInboxProjectCatalog.key(for: project)
        var preferences = agentInboxPreferences
        preferences.hiddenProjectPaths.insert(key)
        preferences.pinnedProjectPaths.remove(key)
        agentInboxPreferences = preferences
        statusMessage = "Hidden \(project.name) from Agent Inbox"
    }

    func hideAgentInboxProjects(_ projects: [AgentInboxProject]) {
        guard !projects.isEmpty else { return }
        var preferences = agentInboxPreferences
        for project in projects {
            let key = AgentInboxProjectCatalog.key(for: project)
            preferences.hiddenProjectPaths.insert(key)
            preferences.pinnedProjectPaths.remove(key)
        }
        agentInboxPreferences = preferences
        statusMessage = "Hidden \(projects.count) project\(projects.count == 1 ? "" : "s") from Agent Inbox"
    }

    func unhideAgentInboxProject(_ project: AgentInboxProject) {
        var preferences = agentInboxPreferences
        preferences.hiddenProjectPaths.remove(AgentInboxProjectCatalog.key(for: project))
        agentInboxPreferences = preferences
        statusMessage = "Restored \(project.name) to Agent Inbox"
    }

    func toggleAgentInboxPin(_ project: AgentInboxProject) {
        let key = AgentInboxProjectCatalog.key(for: project)
        var preferences = agentInboxPreferences
        if preferences.pinnedProjectPaths.contains(key) {
            preferences.pinnedProjectPaths.remove(key)
            statusMessage = "Unpinned \(project.name)"
        } else {
            preferences.pinnedProjectPaths.insert(key)
            preferences.hiddenProjectPaths.remove(key)
            statusMessage = "Pinned \(project.name)"
        }
        agentInboxPreferences = preferences
    }

    private func loadAgentInboxPreferences() {
        guard let data = try? Data(contentsOf: agentInboxPreferencesURL),
            let decoded = try? JSONDecoder().decode(AgentInboxPreferences.self, from: data)
        else { return }
        agentInboxPreferences = decoded
    }

    private func saveAgentInboxPreferences() {
        guard let data = try? JSONEncoder.pretty.encode(agentInboxPreferences) else { return }
        try? data.write(to: agentInboxPreferencesURL, options: .atomic)
    }

    var selectedWorkspace: Workspace? {
        guard let selectedWorkspaceID else { return nil }
        return workspaces.first { $0.id == selectedWorkspaceID }
    }

    var systemBookmarks: [SystemBookmark] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var bookmarks = [
            SystemBookmark(
                id: "desktop", title: "Desktop", systemImage: "rectangle", url: home.appendingPathComponent("Desktop")),
            SystemBookmark(
                id: "downloads", title: "Downloads", systemImage: "arrow.down.circle",
                url: home.appendingPathComponent("Downloads")),
            SystemBookmark(
                id: "documents", title: "Documents", systemImage: "doc", url: home.appendingPathComponent("Documents")),
            SystemBookmark(
                id: "movies", title: "Movies", systemImage: "film", url: home.appendingPathComponent("Movies")),
            SystemBookmark(
                id: "music", title: "Music", systemImage: "music.note", url: home.appendingPathComponent("Music")),
            SystemBookmark(
                id: "pictures", title: "Pictures", systemImage: "photo", url: home.appendingPathComponent("Pictures")),
            SystemBookmark(id: "home", title: NSUserName(), systemImage: "house", url: home),
            SystemBookmark(
                id: "applications", title: "Applications", systemImage: "app.badge",
                url: URL(fileURLWithPath: "/Applications")),
            SystemBookmark(
                id: "trash", title: "Trash", systemImage: "trash", url: home.appendingPathComponent(".Trash")),
        ]

        let iCloud = home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs")
        if FileManager.default.fileExists(atPath: iCloud.path) {
            bookmarks.append(SystemBookmark(id: "icloud", title: "iCloud Drive", systemImage: "icloud", url: iCloud))
        }

        bookmarks.append(
            SystemBookmark(
                id: "macintosh-hd", title: "Macintosh HD", systemImage: "internaldrive", url: URL(fileURLWithPath: "/"))
        )
        return bookmarks
    }

    /// A brand-new workspace starts empty with the Single layout — one pane
    /// showing the "add a folder" placeholder, no directory written in yet.
    func createWorkspace() {
        appendWorkspace(directories: [], layout: .single)
    }

    private func appendWorkspace(directories: [DirectoryItem], layout: WorkspaceLayout = .single) {
        let workspace = Workspace(name: nextWorkspaceName(), layout: layout, directories: directories)
        workspaces.append(workspace)
        selectedWorkspaceID = workspace.id
        save()
    }

    func deleteSelectedWorkspace() {
        guard let selectedWorkspaceID else { return }
        deleteWorkspace(id: selectedWorkspaceID)
    }

    func deleteWorkspace(id: UUID) {
        paneLocations = paneLocations.filter { paneID, _ in
            workspaces.first(where: { $0.id == id })?.directories.contains(where: { $0.id == paneID }) != true
        }
        workspaces.removeAll { $0.id == id }
        if selectedWorkspaceID == id {
            selectedWorkspaceID = workspaces.first?.id
        }
        save()
        savePaneLocations()
    }

    /// Switches the layout. Panes are NOT auto-created: when the layout wants
    /// more panes than there are folders, the grid shows greyed "add a pane"
    /// placeholders for the empty cells instead (see `MultiPaneBrowserView`).
    func applyLayout(_ layout: WorkspaceLayout) {
        guard var workspace = selectedWorkspace else { return }
        workspace.layout = layout
        updateSelectedWorkspace(workspace)
    }

    func updateSelectedWorkspace(_ workspace: Workspace) {
        guard let index = workspaces.firstIndex(where: { $0.id == workspace.id }) else { return }
        workspaces[index] = workspace
        save()
    }

    func renameWorkspace(id: UUID, to name: String) {
        guard let index = workspaces.firstIndex(where: { $0.id == id }) else { return }
        workspaces[index].name = name
        save()
    }

    func addDirectoriesFromOpenPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"

        guard panel.runModal() == .OK else { return }
        addDirectories(panel.urls)
    }

    func addDirectories(_ urls: [URL]) {
        ensureWorkspaceExists()
        guard var workspace = selectedWorkspace else { return }

        let existingPaths = Set(workspace.directories.map(\.path))
        let additions =
            urls
            .filter { existingPaths.contains($0.path) == false }
            .map { DirectoryItem(name: $0.lastPathComponent.isEmpty ? $0.path : $0.lastPathComponent, path: $0.path) }

        workspace.directories.append(contentsOf: additions)
        fitLayoutAfterAddingPanes(&workspace)
        updateSelectedWorkspace(workspace)
        statusMessage = "Added \(additions.count) folder\(additions.count == 1 ? "" : "s")"
    }

    func removeDirectory(_ item: DirectoryItem) {
        guard var workspace = selectedWorkspace else { return }
        workspace.directories.removeAll { $0.id == item.id }
        paneLocations[item.id] = nil
        savePaneLocations()
        paneSortOrders[item.id] = nil
        savePaneSortOrders()
        // Auto-fit the layout to the remaining pane count so closing a pane
        // re-flows the rest instead of leaving an empty placeholder cell.
        workspace.layout = WorkspaceLayout.fitting(paneCount: workspace.directories.count)
        updateSelectedWorkspace(workspace)
    }

    func updatePaneLocation(id: UUID, url: URL) {
        let path = url.path
        guard paneLocations[id] != path else { return }
        paneLocations[id] = path
        savePaneLocations()
    }

    /// Pane navigation survives app restarts: locations are persisted alongside
    /// the workspaces and pruned when their pane/workspace is deleted.
    private func loadPaneLocations() {
        guard let data = try? Data(contentsOf: paneLocationsURL),
            let decoded = try? JSONDecoder().decode([UUID: String].self, from: data)
        else { return }
        paneLocations = decoded
    }

    private func savePaneLocations() {
        guard let data = try? JSONEncoder.pretty.encode(paneLocations) else { return }
        try? data.write(to: paneLocationsURL, options: .atomic)
    }

    // Pane sort order survives workspace switches (which recreate panes) and
    // app restarts, mirroring pane locations.
    private func loadPaneSortOrders() {
        guard let data = try? Data(contentsOf: paneSortOrdersURL),
            let decoded = try? JSONDecoder().decode([UUID: PaneSortOrder].self, from: data)
        else { return }
        paneSortOrders = decoded
    }

    private func savePaneSortOrders() {
        guard let data = try? JSONEncoder.pretty.encode(paneSortOrders) else { return }
        try? data.write(to: paneSortOrdersURL, options: .atomic)
    }

    func paneSortOrder(for id: UUID) -> PaneSortOrder {
        paneSortOrders[id] ?? PaneSortOrder()
    }

    func setPaneSortOrder(_ order: PaneSortOrder, for id: UUID) {
        guard paneSortOrders[id] != order else { return }
        paneSortOrders[id] = order
        savePaneSortOrders()
    }

    func paneLocation(for id: UUID?) -> URL? {
        guard let id else { return nil }
        if let path = paneLocations[id] {
            return URL(fileURLWithPath: path)
        }
        return selectedWorkspace?.directories.first { $0.id == id }.map { URL(fileURLWithPath: $0.path) }
    }

    func paneTitle(for id: UUID?) -> String {
        guard
            let url = paneLocation(for: id)
                ?? selectedWorkspace?.directories.first.map({ URL(fileURLWithPath: $0.path) })
        else {
            return selectedWorkspace?.name ?? "XFinder"
        }
        return url.lastPathComponent.isEmpty ? "Macintosh HD" : url.lastPathComponent
    }

    @discardableResult
    func openLocation(url: URL, title: String, in focusedPaneID: UUID?) -> UUID? {
        guard var workspace = selectedWorkspace else {
            return openInNewPane(url, title: title)
        }
        // Retarget the focused pane, or the first pane if none is focused — never
        // append (that caused panes to pile up on every sidebar click).
        let targetID = focusedPaneID ?? workspace.directories.first?.id
        guard let targetID,
            let index = workspace.directories.firstIndex(where: { $0.id == targetID })
        else {
            return openInNewPane(url, title: title)
        }

        workspace.directories[index].name = title
        workspace.directories[index].path = url.path
        paneLocations[targetID] = url.path
        updateSelectedWorkspace(workspace)
        self.focusedPaneID = targetID
        statusMessage = "Opened \(title)"
        return targetID
    }

    /// Adds a brand-new pane at `url` (no de-duplication) — used to fill a
    /// selected "待添加" placeholder from the sidebar.
    @discardableResult
    func openInNewPane(_ url: URL, title: String) -> UUID? {
        ensureWorkspaceExists()
        guard var workspace = selectedWorkspace else { return nil }
        let item = DirectoryItem(name: title, path: url.path)
        workspace.directories.append(item)
        fitLayoutAfterAddingPanes(&workspace)
        updateSelectedWorkspace(workspace)
        focusedPaneID = item.id
        statusMessage = "Opened \(title)"
        return item.id
    }

    /// Opens Terminal.app with its working directory set to `url`.
    func openTerminal(at url: URL) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-a", "Terminal", url.path]
        do {
            try process.run()
            statusMessage = "Opened Terminal at \(url.lastPathComponent)"
        } catch {
            lastError = error.localizedDescription
            statusMessage = "Could not open Terminal"
        }
    }

    /// Opens a Terminal window at `url` running the interactive Claude Code
    /// CLI — the "hand the directory to an agent" action. Uses AppleScript
    /// (like Finder import) because `open -a Terminal` can't pass a command.
    func openClaudeCode(at url: URL) {
        let shellCommand =
            "cd " + ClaudeBridge.shellQuoted(url.path) + " && "
            + ClaudeBridge.cliCommand(path: settings.claudeCLIPath)
        let escaped =
            shellCommand
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let source = """
            tell application "Terminal"
                activate
                do script "\(escaped)"
            end tell
            """
        var errorInfo: NSDictionary?
        guard let script = NSAppleScript(source: source) else { return }
        script.executeAndReturnError(&errorInfo)
        if let message = errorInfo?[NSAppleScript.errorMessage] as? String {
            lastError = "无法打开 Claude Code：\(message)（首次使用需在弹窗中允许 XFinder 控制 Terminal）"
            statusMessage = "Open Claude Code failed"
        } else {
            statusMessage = "Opened Claude Code at \(url.lastPathComponent)"
        }
    }

    // MARK: - Skill Hub operations

    /// Copies a skill folder into an agent's first writable skills directory —
    /// "distribute this skill to <agent>". No-op (with an error) if the agent
    /// has no writable location. Returns true on success so the UI can rescan.
    @discardableResult
    func installSkill(from source: URL, to agent: SkillAgent) -> Bool {
        guard let directory = agent.scanDirectories.first(where: { !$0.isReadOnly })?.url else {
            lastError = "\(agent.displayName) 没有可写的技能目录。"
            statusMessage = "Install skill failed"
            return false
        }
        let dest = directory.appendingPathComponent(source.lastPathComponent)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try replaceDirectory(at: dest, withContentsOf: source)
            statusMessage = "Installed \(source.lastPathComponent) to \(agent.displayName)"
            return true
        } catch {
            lastError = error.localizedDescription
            statusMessage = "Install skill failed"
            return false
        }
    }

    /// Overwrites `destinations` with the contents of `source` — used to resolve
    /// drift by promoting one copy as canonical. Read-only targets are the
    /// caller's responsibility to exclude.
    @discardableResult
    func syncSkill(from source: URL, to destinations: [URL]) -> Bool {
        var ok = true
        for dest in destinations where dest.standardizedFileURL != source.standardizedFileURL {
            do {
                try replaceDirectory(at: dest, withContentsOf: source)
            } catch {
                lastError = error.localizedDescription
                ok = false
            }
        }
        statusMessage = ok ? "Synced \(source.lastPathComponent)" : "Sync skill failed"
        return ok
    }

    /// Replaces the directory at `dest` with a copy of `source`. Removes any
    /// existing dest first so the copy is a clean mirror (not a merge).
    private func replaceDirectory(at dest: URL, withContentsOf source: URL) throws {
        if FileManager.default.fileExists(atPath: dest.path) {
            try FileManager.default.removeItem(at: dest)
        }
        try FileManager.default.copyItem(at: source, to: dest)
    }

    /// The canonical skill library directory (default `~/Skills`).
    var skillLibraryURL: URL {
        let path = settings.skillLibraryPath.trimmingCharacters(in: .whitespaces)
        if path.isEmpty {
            return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Skills", isDirectory: true)
        }
        return URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    }

    /// Consolidates a skill into the library and replaces each writable copy
    /// with a symlink → one source of truth, no more drift. `canonicalSource`
    /// is the copy whose content seeds the library entry. Read-only/built-in
    /// copies are left untouched.
    @discardableResult
    func consolidateSkill(name: String, canonicalSource: URL, writableLocations: [URL]) -> Bool {
        let library = skillLibraryURL
        let target = library.appendingPathComponent(name, isDirectory: true)
        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(at: library, withIntermediateDirectories: true)
            // Seed/refresh the library entry from the chosen copy.
            try replaceDirectory(at: target, withContentsOf: canonicalSource)
            // Point every writable location at the library via a symlink.
            for location in writableLocations {
                if fileManager.fileExists(atPath: location.path) {
                    try fileManager.removeItem(at: location)
                }
                try fileManager.createSymbolicLink(at: location, withDestinationURL: target)
            }
            statusMessage = "Consolidated \(name) into the skill library"
            return true
        } catch {
            lastError = error.localizedDescription
            statusMessage = "Consolidate skill failed"
            return false
        }
    }

    /// Symlinks a library skill into an agent's writable skills directory.
    @discardableResult
    func linkLibrarySkill(name: String, to agent: SkillAgent) -> Bool {
        guard let directory = agent.scanDirectories.first(where: { !$0.isReadOnly })?.url else {
            lastError = "\(agent.displayName) 没有可写的技能目录。"
            return false
        }
        let target = skillLibraryURL.appendingPathComponent(name, isDirectory: true)
        guard FileManager.default.fileExists(atPath: target.path) else {
            lastError = "技能库中没有 \(name)。"
            return false
        }
        let link = directory.appendingPathComponent(name)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: link.path) {
                try FileManager.default.removeItem(at: link)
            }
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
            statusMessage = "Linked \(name) to \(agent.displayName)"
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    // MARK: - Stars (favourite directories)

    func isStarred(_ url: URL) -> Bool {
        stars.contains { $0.path == url.path }
    }

    func toggleStar(_ url: URL) {
        if let existing = stars.first(where: { $0.path == url.path }) {
            removeStar(existing)
        } else {
            let name = url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent
            stars.append(StarItem(name: name, path: url.path))
            saveStars()
            statusMessage = "Starred \(name)"
        }
    }

    func removeStar(_ star: StarItem) {
        stars.removeAll { $0.id == star.id }
        saveStars()
    }

    private func loadStars() {
        guard let data = try? Data(contentsOf: starsURL),
            let decoded = try? JSONDecoder().decode([StarItem].self, from: data)
        else { return }
        stars = decoded
    }

    private func saveStars() {
        do {
            let data = try JSONEncoder.pretty.encode(stars)
            try data.write(to: starsURL, options: .atomic)
        } catch {
            lastError = "Could not save stars: \(error.localizedDescription)"
        }
    }

    func paneDestinations(excluding id: UUID) -> [PaneDestination] {
        guard let workspace = selectedWorkspace else { return [] }
        return workspace.directories
            .filter { $0.id != id }
            .map { directory in
                let path = paneLocations[directory.id] ?? directory.path
                return PaneDestination(id: directory.id, name: path, url: URL(fileURLWithPath: path))
            }
    }

    func copy(_ sourceURL: URL, to destination: PaneDestination) {
        do {
            let target = uniqueDestinationURL(for: sourceURL, in: destination.url)
            try FileManager.default.copyItem(at: sourceURL, to: target)
            registerHistory(
                title: "Copy \(sourceURL.lastPathComponent)",
                undo: .remove(target),
                redo: .copy(from: sourceURL, to: target)
            )
            fileOperationRevision += 1
            statusMessage = "Copied \(sourceURL.lastPathComponent) to \(destination.name)"
        } catch {
            lastError = error.localizedDescription
            statusMessage = "Copy failed"
        }
    }

    func copy(_ sourceURL: URL, toDirectory destinationURL: URL) {
        do {
            let target = uniqueDestinationURL(for: sourceURL, in: destinationURL)
            try FileManager.default.copyItem(at: sourceURL, to: target)
            registerHistory(
                title: "Copy \(sourceURL.lastPathComponent)",
                undo: .remove(target),
                redo: .copy(from: sourceURL, to: target)
            )
            fileOperationRevision += 1
            statusMessage = "Copied \(sourceURL.lastPathComponent)"
        } catch {
            lastError = error.localizedDescription
            statusMessage = "Copy failed"
        }
    }

    func move(_ sourceURL: URL, to destination: PaneDestination) {
        move(sourceURL, toDirectory: destination.url, destinationName: destination.name)
    }

    func move(_ sourceURL: URL, toDirectory destinationURL: URL, destinationName: String? = nil) {
        do {
            guard sourceURL.deletingLastPathComponent().standardizedFileURL != destinationURL.standardizedFileURL else {
                statusMessage = "\(sourceURL.lastPathComponent) is already in this folder"
                return
            }
            let target = uniqueDestinationURL(for: sourceURL, in: destinationURL)
            try FileManager.default.moveItem(at: sourceURL, to: target)
            registerHistory(
                title: "Move \(sourceURL.lastPathComponent)",
                undo: .move(from: target, to: sourceURL),
                redo: .move(from: sourceURL, to: target)
            )
            fileOperationRevision += 1
            statusMessage = "Moved \(sourceURL.lastPathComponent) to \(destinationName ?? destinationURL.path)"
        } catch {
            lastError = error.localizedDescription
            statusMessage = "Move failed"
        }
    }

    func renameFile(_ sourceURL: URL, to newName: String) {
        let trimmedName = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, trimmedName != sourceURL.lastPathComponent else { return }

        do {
            let target = sourceURL.deletingLastPathComponent().appendingPathComponent(trimmedName)
            guard !FileManager.default.fileExists(atPath: target.path) else {
                lastError = "A file named \(trimmedName) already exists."
                statusMessage = "Rename failed"
                return
            }
            try FileManager.default.moveItem(at: sourceURL, to: target)
            registerHistory(
                title: "Rename \(sourceURL.lastPathComponent)",
                undo: .move(from: target, to: sourceURL),
                redo: .move(from: sourceURL, to: target)
            )
            fileOperationRevision += 1
            statusMessage = "Renamed \(sourceURL.lastPathComponent) to \(trimmedName)"
        } catch {
            lastError = error.localizedDescription
            statusMessage = "Rename failed"
        }
    }

    @discardableResult
    func createFolder(in directory: URL, named name: String = "新建文件夹") -> URL? {
        let target = uniqueDestinationURL(for: directory.appendingPathComponent(name), in: directory)
        do {
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
            registerHistory(
                title: "Create \(target.lastPathComponent)",
                undo: .remove(target),
                redo: .createDirectory(target)
            )
            fileOperationRevision += 1
            statusMessage = "Created \(target.lastPathComponent)"
            return target
        } catch {
            lastError = error.localizedDescription
            statusMessage = "New folder failed"
            return nil
        }
    }

    @discardableResult
    func createMarkdownFile(in directory: URL, named name: String = "New") -> URL? {
        let target = uniqueDestinationURL(
            for: directory.appendingPathComponent("\(name).md"),
            in: directory,
            firstDuplicateIndex: 1
        )
        do {
            try Data().write(to: target, options: .withoutOverwriting)
            registerHistory(
                title: "Create \(target.lastPathComponent)",
                undo: .remove(target),
                redo: .createEmptyFile(target)
            )
            fileOperationRevision += 1
            statusMessage = "Created \(target.lastPathComponent)"
            return target
        } catch {
            lastError = error.localizedDescription
            statusMessage = "New Markdown failed"
            return nil
        }
    }

    /// Zips `urls` into `<archiveName>.zip` placed in `outputDirectory`. Archive
    /// entries are stored relative to `baseDirectory` so the zip keeps clean,
    /// nested paths. Runs `/usr/bin/zip` asynchronously so the UI never blocks;
    /// completion updates state via `fileOperationRevision`.
    @discardableResult
    func compress(_ urls: [URL], relativeTo baseDirectory: URL, archiveName: String, into outputDirectory: URL) -> URL?
    {
        guard !urls.isEmpty else { return nil }

        let target = uniqueDestinationURL(
            for: outputDirectory.appendingPathComponent("\(archiveName).zip"),
            in: outputDirectory
        )
        guard canCreateFile(in: outputDirectory) else {
            lastError = "Compression failed: cannot create files in \(outputDirectory.path)."
            statusMessage = "Compress failed"
            return nil
        }

        let process = Process()
        let processID = UUID()
        let standardError = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.currentDirectoryURL = baseDirectory
        process.standardError = standardError
        process.arguments = ["-r", "-X", target.path] + urls.map { relativePath(of: $0, under: baseDirectory) }

        let count = urls.count
        let finalName = target.lastPathComponent
        process.terminationHandler = { [weak self, standardError] finished in
            let status = finished.terminationStatus
            let reason = finished.terminationReason
            let errorText =
                String(data: standardError.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            Task { @MainActor in
                guard let self else { return }
                self.runningCompressionProcesses[processID] = nil
                self.finishFileTask(id: processID)
                if reason == .exit && status == 0 {
                    self.registerHistory(
                        title: "Compress \(finalName)",
                        undo: .remove(target),
                        redo: nil
                    )
                    self.fileOperationRevision += 1
                    self.statusMessage = "Compressed \(count) item\(count == 1 ? "" : "s") to \(finalName)"
                } else {
                    self.lastError = self.compressionFailureMessage(
                        status: status,
                        reason: reason,
                        standardError: errorText,
                        outputDirectory: outputDirectory
                    )
                    self.statusMessage = "Compress failed"
                }
            }
        }

        do {
            runningCompressionProcesses[processID] = process
            beginFileTask(
                id: processID,
                title: "Compressing \(count) item\(count == 1 ? "" : "s")",
                detail: finalName,
                isCancellable: true
            )
            try process.run()
            statusMessage = "Compressing \(count) item\(count == 1 ? "" : "s")…"
            return target
        } catch {
            runningCompressionProcesses[processID] = nil
            finishFileTask(id: processID)
            lastError = error.localizedDescription
            statusMessage = "Compress failed"
            return nil
        }
    }

    private func canCreateFile(in directory: URL) -> Bool {
        let probe = directory.appendingPathComponent(".xfinder-write-test-\(UUID().uuidString)")
        do {
            try Data().write(to: probe, options: .withoutOverwriting)
            try? FileManager.default.removeItem(at: probe)
            return true
        } catch {
            return false
        }
    }

    private func compressionFailureMessage(
        status: Int32,
        reason: Process.TerminationReason,
        standardError: String,
        outputDirectory: URL
    ) -> String {
        let reasonText =
            switch reason {
            case .exit:
                if status == 15 {
                    "zip could not create the archive in \(outputDirectory.path)"
                } else {
                    "zip exited with code \(status)"
                }
            case .uncaughtSignal:
                "zip was terminated by signal \(status)"
            @unknown default:
                "zip ended with code \(status)"
            }
        guard !standardError.isEmpty else {
            return "Compression failed (\(reasonText))."
        }
        return "Compression failed (\(reasonText)): \(standardError)"
    }

    private func relativePath(of url: URL, under base: URL) -> String {
        let basePath = base.path.hasSuffix("/") ? base.path : base.path + "/"
        if url.path.hasPrefix(basePath) {
            return String(url.path.dropFirst(basePath.count))
        }
        return url.lastPathComponent
    }

    func moveToTrash(_ sourceURL: URL) {
        do {
            var resultingURL: NSURL?
            try FileManager.default.trashItem(at: sourceURL, resultingItemURL: &resultingURL)
            if let trashedURL = resultingURL as URL? {
                registerHistory(
                    title: "Move \(sourceURL.lastPathComponent) to Trash",
                    undo: .move(from: trashedURL, to: sourceURL),
                    redo: .trash(sourceURL)
                )
            }
            fileOperationRevision += 1
            statusMessage = "Moved \(sourceURL.lastPathComponent) to Trash"
        } catch {
            lastError = error.localizedDescription
            statusMessage = "Move to Trash failed"
        }
    }

    @discardableResult
    func duplicate(_ sourceURL: URL) -> URL? {
        let target = duplicateDestinationURL(for: sourceURL)
        do {
            try FileManager.default.copyItem(at: sourceURL, to: target)
            registerHistory(
                title: "Duplicate \(sourceURL.lastPathComponent)",
                undo: .remove(target),
                redo: .copy(from: sourceURL, to: target)
            )
            fileOperationRevision += 1
            statusMessage = "Duplicated \(sourceURL.lastPathComponent)"
            return target
        } catch {
            lastError = error.localizedDescription
            statusMessage = "Duplicate failed"
            return nil
        }
    }

    func undoLastFileOperation() {
        guard let entry = undoStack.popLast() else { return }
        do {
            _ = try applyHistoryOperation(entry.undo)
            if entry.redo != nil {
                redoStack.append(entry)
            }
            updateHistoryAvailability()
            fileOperationRevision += 1
            statusMessage = "Undid \(entry.title)"
        } catch {
            undoStack.append(entry)
            updateHistoryAvailability()
            lastError = error.localizedDescription
            statusMessage = "Undo failed"
        }
    }

    func redoLastFileOperation() {
        guard let entry = redoStack.popLast(), let redo = entry.redo else { return }
        do {
            let updatedUndo = try applyHistoryOperation(redo) ?? entry.undo
            undoStack.append(FileHistoryEntry(title: entry.title, undo: updatedUndo, redo: entry.redo))
            updateHistoryAvailability()
            fileOperationRevision += 1
            statusMessage = "Redid \(entry.title)"
        } catch {
            redoStack.append(entry)
            updateHistoryAvailability()
            lastError = error.localizedDescription
            statusMessage = "Redo failed"
        }
    }

    func cancelFileTask(id: UUID) {
        guard let process = runningCompressionProcesses[id] else { return }
        process.terminate()
        statusMessage = "Cancelling file task…"
    }

    func importOpenFinderWindows() {
        do {
            let urls = try finderController.currentFinderWindowDirectories()
            guard !urls.isEmpty else {
                statusMessage = "No open Finder windows to import"
                lastError = "没有找到已打开的 Finder 窗口可导入。请先在 Finder 中打开窗口；首次使用时请在弹出的授权框里允许 XFinder 控制 Finder。"
                return
            }
            addDirectories(urls)
            statusMessage = "Imported \(urls.count) Finder window\(urls.count == 1 ? "" : "s")"
        } catch {
            lastError = error.localizedDescription
            statusMessage = "Could not import Finder windows"
        }
    }

    /// Every pane-adding path must call this: when the pane count exceeds what
    /// the current layout can show, the grid silently wraps panes into extra
    /// rows the Layout control doesn't represent. Upgrades the layout to fit;
    /// never downgrades, so a roomier layout keeps its "待添加" placeholders.
    private func fitLayoutAfterAddingPanes(_ workspace: inout Workspace) {
        guard let preferred = workspace.layout.preferredPaneCount,
            workspace.directories.count > preferred
        else { return }
        workspace.layout = WorkspaceLayout.fitting(paneCount: workspace.directories.count)
    }

    private func ensureWorkspaceExists() {
        if selectedWorkspace == nil {
            appendWorkspace(directories: [])
        }
    }

    private func registerHistory(title: String, undo: FileHistoryOperation, redo: FileHistoryOperation?) {
        undoStack.append(FileHistoryEntry(title: title, undo: undo, redo: redo))
        redoStack.removeAll()
        updateHistoryAvailability()
    }

    private func updateHistoryAvailability() {
        canUndoFileOperation = !undoStack.isEmpty
        canRedoFileOperation = !redoStack.isEmpty
    }

    private func applyHistoryOperation(_ operation: FileHistoryOperation) throws -> FileHistoryOperation? {
        switch operation {
        case .remove(let url):
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
            return nil
        case .move(let source, let target):
            guard FileManager.default.fileExists(atPath: source.path) else {
                throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: source.path])
            }
            guard !FileManager.default.fileExists(atPath: target.path) else {
                throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: target.path])
            }
            try FileManager.default.moveItem(at: source, to: target)
            return .move(from: target, to: source)
        case .copy(let source, let target):
            guard FileManager.default.fileExists(atPath: source.path) else {
                throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: source.path])
            }
            guard !FileManager.default.fileExists(atPath: target.path) else {
                throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: target.path])
            }
            try FileManager.default.copyItem(at: source, to: target)
            return .remove(target)
        case .trash(let url):
            var resultingURL: NSURL?
            try FileManager.default.trashItem(at: url, resultingItemURL: &resultingURL)
            guard let trashedURL = resultingURL as URL? else { return nil }
            return .move(from: trashedURL, to: url)
        case .createDirectory(let url):
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
            return .remove(url)
        case .createEmptyFile(let url):
            try Data().write(to: url, options: .withoutOverwriting)
            return .remove(url)
        }
    }

    private func beginFileTask(id: UUID, title: String, detail: String, isCancellable: Bool) {
        fileTasks.removeAll { $0.id == id }
        fileTasks.append(FileTask(id: id, title: title, detail: detail, isCancellable: isCancellable))
    }

    private func finishFileTask(id: UUID) {
        fileTasks.removeAll { $0.id == id }
    }

    private func load() {
        guard let data = try? Data(contentsOf: persistenceURL),
            let decoded = try? JSONDecoder().decode([Workspace].self, from: data)
        else {
            let defaultWorkspace = Workspace(
                name: "Daily Desk",
                layout: .columns2,
                directories: [
                    DirectoryItem(
                        name: "Desktop",
                        path: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop").path),
                    DirectoryItem(
                        name: "Downloads",
                        path: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads").path),
                ]
            )
            workspaces = [defaultWorkspace]
            selectedWorkspaceID = defaultWorkspace.id
            save()
            return
        }

        workspaces = decoded
        selectedWorkspaceID = decoded.first?.id
    }

    private func save() {
        do {
            let data = try JSONEncoder.pretty.encode(workspaces)
            try data.write(to: persistenceURL, options: .atomic)
        } catch {
            lastError = "Could not save workspaces: \(error.localizedDescription)"
        }
    }

    private func nextWorkspaceName() -> String {
        let base = "Workspace"
        var index = workspaces.count + 1
        var candidate = "\(base) \(index)"
        let names = Set(workspaces.map(\.name))
        while names.contains(candidate) {
            index += 1
            candidate = "\(base) \(index)"
        }
        return candidate
    }

    private func uniqueDestinationURL(
        for sourceURL: URL,
        in destinationDirectory: URL,
        firstDuplicateIndex: Int = 2
    ) -> URL {
        let fileManager = FileManager.default
        let baseName = sourceURL.deletingPathExtension().lastPathComponent
        let pathExtension = sourceURL.pathExtension
        var candidate = destinationDirectory.appendingPathComponent(sourceURL.lastPathComponent)
        var index = firstDuplicateIndex

        while fileManager.fileExists(atPath: candidate.path) {
            let name = pathExtension.isEmpty ? "\(baseName) \(index)" : "\(baseName) \(index).\(pathExtension)"
            candidate = destinationDirectory.appendingPathComponent(name)
            index += 1
        }

        return candidate
    }

    private func duplicateDestinationURL(for sourceURL: URL) -> URL {
        let directory = sourceURL.deletingLastPathComponent()
        let baseName = sourceURL.deletingPathExtension().lastPathComponent
        let pathExtension = sourceURL.pathExtension
        let firstName = pathExtension.isEmpty ? "\(baseName) copy" : "\(baseName) copy.\(pathExtension)"
        var candidate = directory.appendingPathComponent(firstName)
        var index = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            let name =
                pathExtension.isEmpty ? "\(baseName) copy \(index)" : "\(baseName) copy \(index).\(pathExtension)"
            candidate = directory.appendingPathComponent(name)
            index += 1
        }
        return candidate
    }
}

private extension JSONEncoder {
    static var pretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}
