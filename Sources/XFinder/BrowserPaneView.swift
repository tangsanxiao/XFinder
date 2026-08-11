import SwiftUI
import UniformTypeIdentifiers

struct BrowserPane: View {
    @Environment(\.openWindow) private var openWindow
    @EnvironmentObject private var store: WorkspaceStore
    @EnvironmentObject private var speechController: ReadAloudController
    let root: DirectoryItem
    let isFocused: Bool
    let viewMode: BrowserViewMode
    let onViewModeChange: (BrowserViewMode) -> Void
    let onFocus: () -> Void

    @State private var currentURL: URL
    @State private var backStack: [URL] = []
    @State private var forwardStack: [URL] = []
    @State private var items: [BrowserFileItem] = []
    @State private var expandedFolders: Set<String> = []
    @State private var expandedContents: [String: [BrowserFileItem]] = [:]
    @State private var stableDirectoryModificationDates: [String: Date] = [:]
    @State private var selection: Set<BrowserFileItem.ID> = []
    @State private var selectionAnchor: BrowserFileItem.ID?
    @State private var renamingFileID: BrowserFileItem.ID?
    @State private var renameDraft = ""
    @State private var pendingRenameTask: Task<Void, Never>?
    @State private var columnWidths = FileListColumnWidths()
    @State private var resizeStartWidths: FileListColumnWidths?
    @State private var errorMessage: String?
    /// Live mirror of `viewMode` for code reachable from the key monitor: the
    /// monitor closure freezes the view-struct's lets at install time, but
    /// @State storage stays current across renders.
    @State private var liveViewMode: BrowserViewMode = .list
    /// Scroll-into-view request for keyboard selection: a row id (list view)
    /// or file id (icons view) consumed by the ScrollViewReader onChange.
    @State private var keyboardScrollTarget: String?
    @State private var pendingSelectionURL: URL?
    /// Set when entering a folder from the keyboard (Cmd+↓): select its first
    /// item after the reload so arrow keys keep working.
    @State private var pendingSelectFirstItem = false
    @State private var showsHiddenItems = false
    @State private var showsFilter = false
    @State private var filterText = ""
    /// nil = show all categories; otherwise only items of this category (plus
    /// folders, so you can still navigate into subdirs while filtering files).
    @State private var categoryFilter: FileCategory?
    @FocusState private var filterFieldFocused: Bool
    @State private var showsGoToPath = false
    @State private var goToPathText = ""
    @State private var keyMonitor: Any?
    @State private var hostingWindowNumber: Int?
    @State private var scheduledReloadTask: Task<Void, Never>?
    @State private var gitSnapshot: GitDirectorySnapshot?
    @State private var showsProjectCard = false
    @State private var showsAnalysis = false
    @State private var analysisRunning = false
    @State private var analysisText: String?
    @State private var analysisError: String?
    @State private var analysisTask: Task<Void, Never>?
    @State private var analysisQuestion = ""
    @State private var showsDiff = false
    @State private var diffFileName = ""
    @State private var diffLoading = false
    @State private var diffLines: [DiffLine] = []
    @State private var diffTask: Task<Void, Never>?
    @State private var infoSnapshot: FileInfoSnapshot?
    @State private var showsRecursiveSearch = false
    @State private var searchQuery = ""
    @State private var searchResults: [FileSearchResult] = []
    @State private var searchRunning = false
    @State private var searchError: String?
    @State private var searchTask: Task<Void, Never>?
    // Reloads run async (directory IO happens off the main thread); the
    // generation counter drops results from a reload that another, newer
    // reload has superseded so a slow folder can't overwrite a fast one.
    @State private var loadGeneration = 0

    init(
        root: DirectoryItem,
        initialURL: URL? = nil,
        isFocused: Bool,
        viewMode: BrowserViewMode,
        onViewModeChange: @escaping (BrowserViewMode) -> Void,
        onFocus: @escaping () -> Void
    ) {
        self.root = root
        self.isFocused = isFocused
        self.viewMode = viewMode
        self.onViewModeChange = onViewModeChange
        self.onFocus = onFocus
        _currentURL = State(initialValue: initialURL ?? URL(fileURLWithPath: root.path))
    }

    var body: some View {
        VStack(spacing: 0) {
            paneToolbar
                .zIndex(2)
            Divider()
                .zIndex(2)
            filterBar
                .zIndex(2)
            if viewMode != .columns {
                tableHeader
                    .zIndex(1)
                Divider()
                    .zIndex(1)
            }

            if let errorMessage {
                EmptyStateView(
                    title: "Cannot Open Folder", systemImage: "exclamationmark.triangle", description: errorMessage)
            } else {
                fileContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .clipped()
                    .contentShape(Rectangle())
                    .contextMenu { emptyAreaMenu }
                    // Double-click an empty area to go up one directory. Rows
                    // recognize their own double-tap (open), which takes
                    // precedence, so this only fires on blank space.
                    .onTapGesture(count: 2) {
                        onFocus()
                        goUp()
                    }
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .background(HostingWindowNumberReader(windowNumber: $hostingWindowNumber))
        .clipShape(RoundedRectangle(cornerRadius: isFocused ? 16 : 0))
        .overlay {
            RoundedRectangle(cornerRadius: isFocused ? 16 : 0)
                .stroke(isFocused ? Color.accentColor : Color.clear, lineWidth: 2)
        }
        .simultaneousGesture(TapGesture().onEnded { onFocus() })
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            dropOnPaneBackground(providers)
        }
        .onAppear {
            // Keyboard navigation: a local monitor per pane; only the focused
            // pane consumes events, all others pass them through.
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                handleKeyDown(event)
            }
        }
        .onDisappear {
            if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
            keyMonitor = nil
            scheduledReloadTask?.cancel()
            scheduledReloadTask = nil
        }
        .sheet(isPresented: $showsGoToPath) {
            goToPathSheet
        }
        .sheet(item: $infoSnapshot) { snapshot in
            FileInfoSheet(
                snapshot: snapshot,
                chinese: store.settings.language.isChineseResolved,
                onReveal: { NSWorkspace.shared.activateFileViewerSelecting([snapshot.url]) },
                onClose: { infoSnapshot = nil }
            )
        }
        .sheet(isPresented: $showsRecursiveSearch, onDismiss: { cancelSearch() }) {
            FileSearchSheet(
                root: currentURL,
                query: $searchQuery,
                results: searchResults,
                isSearching: searchRunning,
                errorText: searchError,
                chinese: store.settings.language.isChineseResolved,
                onSearch: { runRecursiveSearch() },
                onOpen: { url in
                    showsRecursiveSearch = false
                    revealRecentChange(url)
                },
                onClose: { showsRecursiveSearch = false }
            )
        }
        .sheet(isPresented: $showsDiff, onDismiss: { diffTask?.cancel() }) {
            DiffSheet(
                fileName: diffFileName,
                chinese: store.settings.language.isChineseResolved,
                isLoading: diffLoading,
                lines: diffLines,
                claudeEnabled: store.settings.claudeIntegrationEnabled,
                onExplain: { explainCurrentDiff() },
                onClose: { showsDiff = false }
            )
        }
        .sheet(isPresented: $showsAnalysis, onDismiss: { cancelAnalysis() }) {
            ClaudeAnalysisSheet(
                directoryName: currentURL.lastPathComponent,
                question: $analysisQuestion,
                isRunning: analysisRunning,
                resultText: analysisText,
                errorText: analysisError,
                onRun: { runAnalysis() },
                onClose: { showsAnalysis = false }
            )
        }
        .task(id: currentURL) {
            await reload()
            // Auto-refresh when the directory (or an expanded subfolder) changes
            // on disk — files added/removed/renamed or their contents edited.
            var pendingWatcherReload: Task<Void, Never>?
            defer { pendingWatcherReload?.cancel() }
            for await _ in DirectoryWatcher.changes(of: currentURL) {
                pendingWatcherReload?.cancel()
                let watchedURL = currentURL
                let watchedHiddenMode = showsHiddenItems
                pendingWatcherReload = Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(650))
                    guard !Task.isCancelled,
                        currentURL == watchedURL,
                        showsHiddenItems == watchedHiddenMode
                    else { return }
                    await reloadPreservingExpansion()
                }
            }
        }
        .onChange(of: store.fileOperationRevision) { _ in
            scheduleReload(selecting: pendingSelectionURL)
        }
        .onAppear { liveViewMode = viewMode }
        .onChange(of: viewMode) { liveViewMode = $0 }
        .onChange(of: root.path) { newPath in
            currentURL = URL(fileURLWithPath: newPath)
            backStack.removeAll()
            forwardStack.removeAll()
            expandedFolders.removeAll()
            expandedContents.removeAll()
            stableDirectoryModificationDates.removeAll()
        }
        .onReceive(NotificationCenter.default.publisher(for: .xfinderPaneCommand)) { notification in
            guard let command = notification.object as? PaneCommand else { return }
            handlePaneCommand(command)
        }
    }

    @ViewBuilder
    private var fileContent: some View {
        switch viewMode {
        case .icons:
            ScrollViewReader { scrollProxy in
                ScrollView {
                    iconsGrid
                }
                .onChange(of: keyboardScrollTarget) { target in
                    guard let target else { return }
                    scrollProxy.scrollTo(target)
                    keyboardScrollTarget = nil
                }
            }
        case .list:
            listContent
        case .columns:
            columnContent
        }
    }

    private var iconsGrid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: 10)], spacing: 12) {
            ForEach(sortedItems) { file in
                IconFileCell(
                    file: file,
                    isSelected: selection.contains(file.id),
                    isActivePane: isFocused,
                    isRenaming: renamingFileID == file.id,
                    renameDraft: $renameDraft,
                    select: {
                        onFocus()
                        handleRowTap(file)
                    },
                    nameClick: {
                        onFocus()
                        handleNameClick(file)
                    },
                    commitRename: { commitRename(file) },
                    cancelRename: { cancelRename() },
                    rename: {
                        onFocus()
                        beginRename(file)
                    },
                    open: {
                        onFocus()
                        open(file)
                    },
                    copyFiles: {
                        onFocus()
                        copyTargetsToPasteboard(of: file)
                    },
                    copyPath: {
                        onFocus()
                        copyPath(file.url.path)
                    },
                    reveal: {
                        onFocus()
                        NSWorkspace.shared.activateFileViewerSelecting([file.url])
                    },
                    trash: {
                        onFocus()
                        trashTargets(of: file)
                    },
                    compress: {
                        onFocus()
                        compress(file)
                    },
                    duplicate: {
                        onFocus()
                        duplicateTargets(of: file)
                    },
                    getInfo: {
                        onFocus()
                        showInfo(for: file.url)
                    },
                    quickLook: {
                        onFocus()
                        quickLook(actionTargets(for: file))
                    },
                    canReadAloud: canReadAloud(file),
                    readAloud: { startReadAloud(file) },
                    canBrowseInline: canBrowseInline(file),
                    destinations: destinations,
                    copyTo: { destination in copyTargets(of: file, to: destination) },
                    moveTo: { destination in moveTargets(of: file, to: destination) },
                    onBeginDrag: { beginDrag(file) },
                    dropInto: { providers in dropOnFolder(file.url, providers: providers) }
                )
            }
        }
        .padding(12)
    }

    private var listContent: some View {
        GeometryReader { proxy in
            let widths = resolvedColumnWidths(for: proxy.size.width)
            let rows = flatRows

            let usedHeight = CGFloat(rows.count) * FileRowMetrics.height
            let fillerHeight = max(0, proxy.size.height - usedHeight)

            ScrollViewReader { scrollProxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(rows) { row in
                            FileRow(
                                file: row.file,
                                depth: row.depth,
                                gitStatus: gitSnapshot?.status(
                                    forPath: row.file.id, isDirectory: row.file.isDirectory),
                                isExpanded: expandedFolders.contains(row.file.id),
                                isSelected: selection.contains(row.file.id),
                                isActivePane: isFocused,
                                isAlternate: !row.ordinal.isMultiple(of: 2),
                                canBrowseInline: canBrowseInline(row.file),
                                isRenaming: renamingFileID == row.file.id,
                                columnWidths: widths,
                                renameDraft: $renameDraft,
                                destinations: destinations,
                                select: {
                                    onFocus()
                                    handleRowTap(row.file)
                                },
                                nameClick: {
                                    onFocus()
                                    handleNameClick(row.file)
                                },
                                commitRename: { commitRename(row.file) },
                                cancelRename: { cancelRename() },
                                rename: {
                                    onFocus()
                                    beginRename(row.file)
                                },
                                open: {
                                    onFocus()
                                    open(row.file)
                                },
                                toggleExpansion: {
                                    onFocus()
                                    toggleExpansion(row.file)
                                },
                                copyFiles: {
                                    onFocus()
                                    copyTargetsToPasteboard(of: row.file)
                                },
                                copyPath: {
                                    onFocus()
                                    copyPath(row.file.url.path)
                                },
                                reveal: { NSWorkspace.shared.activateFileViewerSelecting([row.file.url]) },
                                trash: { trashTargets(of: row.file) },
                                compress: { compress(row.file) },
                                duplicate: { duplicateTargets(of: row.file) },
                                getInfo: { showInfo(for: row.file.url) },
                                quickLook: { quickLook(actionTargets(for: row.file)) },
                                canReadAloud: canReadAloud(row.file),
                                readAloud: { startReadAloud(row.file) },
                                claudeEnabled: store.settings.claudeIntegrationEnabled,
                                askClaude: { askClaudeAboutSelection(row.file) },
                                copyTo: { destination in copyTargets(of: row.file, to: destination) },
                                moveTo: { destination in moveTargets(of: row.file, to: destination) },
                                onBeginDrag: { beginDrag(row.file) },
                                dropInto: { providers in dropOnFolder(row.file.url, providers: providers) }
                            )
                            .frame(width: proxy.size.width, alignment: .leading)
                            .clipped()
                        }

                        // Continue the alternating bands into the empty space
                        // below the last file so the list looks like Finder's.
                        // Bounded to the viewport height, so it stays cheap even
                        // for huge folders (where there is no filler at all).
                        if fillerHeight > 0 {
                            ListStripeFiller(startIndex: rows.count)
                                .frame(width: proxy.size.width, height: fillerHeight)
                        }
                    }
                    .frame(width: proxy.size.width, alignment: .leading)
                }
                .background(Color(nsColor: .controlBackgroundColor))
                // Keyboard selection must stay visible: without this, ↑/↓
                // can move the highlight outside the viewport and the
                // "cursor" silently disappears.
                .onChange(of: keyboardScrollTarget) { target in
                    guard let target else { return }
                    scrollProxy.scrollTo(target)
                    keyboardScrollTarget = nil
                }
            }
        }
    }

    @ViewBuilder
    private var filterBar: some View {
        if showsFilter {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField(store.loc("过滤当前目录", "Filter this folder"), text: $filterText)
                    .textFieldStyle(.plain)
                    .focused($filterFieldFocused)
                    .onExitCommand { dismissFilter() }
                if !filterText.isEmpty {
                    Button {
                        filterText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
                Button(store.loc("完成", "Done")) { dismissFilter() }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
            .font(.system(size: 12))
            .padding(.horizontal, 12)
            .frame(height: 28)
            .background(Color(nsColor: .controlBackgroundColor))
            Divider()
        }
    }

    private var goToPathSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(store.loc("前往文件夹", "Go to Folder"))
                .font(.headline)
            TextField(store.loc("输入路径，如 ~/Documents", "Enter a path, e.g. ~/Documents"), text: $goToPathText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 380)
                .onSubmit { goToEnteredPath() }
            HStack {
                Spacer()
                Button(store.loc("取消", "Cancel")) {
                    showsGoToPath = false
                    goToPathText = ""
                }
                Button(store.loc("前往", "Go")) { goToEnteredPath() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
    }

    private func dismissFilter() {
        filterText = ""
        showsFilter = false
        filterFieldFocused = false
    }

    private func goToEnteredPath() {
        let expanded = (goToPathText as NSString).expandingTildeInPath
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: expanded, isDirectory: &isDirectory), isDirectory.boolValue else {
            store.lastError = store.loc(
                "路径不存在或不是文件夹：\(goToPathText)", "Path doesn't exist or isn't a folder: \(goToPathText)")
            return
        }
        showsGoToPath = false
        goToPathText = ""
        navigate(to: URL(fileURLWithPath: expanded))
    }

    // MARK: - Keyboard navigation

    /// Handles a key event for this pane; returns nil to consume it. Events are
    /// passed through while another window/pane is focused, renaming, or typing
    /// in any text field.
    private func handleKeyDown(_ event: NSEvent) -> NSEvent? {
        // Focus MUST be read live from the store, not from the captured
        // `isFocused` let: the monitor closure holds the view-struct copy from
        // install time, whose lets are frozen — the pane focused back then
        // would keep consuming keys forever. The store reference stays current.
        guard NSApp.keyWindow?.windowNumber == hostingWindowNumber,
            store.focusedPaneID == root.id,
            renamingFileID == nil,
            showsGoToPath == false,
            showsAnalysis == false
        else { return event }
        if NSApp.keyWindow?.firstResponder is NSTextView { return event }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        switch event.keyCode {
        case 125:  // Down
            if modifiers.contains(.command) {
                openSingleSelection()
            } else {
                moveSelection(forward: true, extend: modifiers.contains(.shift))
            }
            return nil
        case 126:  // Up
            if modifiers.contains(.command) {
                goUp()
            } else {
                moveSelection(forward: false, extend: modifiers.contains(.shift))
            }
            return nil
        case 124:  // Right — expand the selected folder inline (list view)
            setSelectedFolderExpansion(true)
            return nil
        case 123:  // Left — collapse it
            setSelectedFolderExpansion(false)
            return nil
        case 36:  // Return — rename, Finder-style
            if let id = singleSelection, let file = loadedFiles.first(where: { $0.id == id }) {
                beginRename(file)
            }
            return nil
        case 51 where modifiers.contains(.command):  // Cmd+Delete — trash
            trashSelection()
            return nil
        case 5 where modifiers.contains(.command) && modifiers.contains(.shift):  // Cmd+Shift+G
            showsGoToPath = true
            return nil
        case 3 where modifiers == [.command, .option]:  // Cmd+Option+F — recursive search
            showRecursiveSearch()
            return nil
        case 0 where modifiers == [.command]:  // Cmd+A — select all visible items
            selectAllVisibleItems()
            return nil
        case 8 where modifiers == [.command]:  // Cmd+C — copy selection to pasteboard
            copySelectionToPasteboard()
            return nil
        case 9 where modifiers == [.command]:  // Cmd+V — paste files here
            pasteFromPasteboard()
            return nil
        case 6 where modifiers == [.command, .shift]:  // Cmd+Shift+Z — redo file operation
            store.redoLastFileOperation()
            return nil
        case 6 where modifiers == [.command]:  // Cmd+Z — undo file operation
            store.undoLastFileOperation()
            return nil
        case 3 where modifiers == [.command]:  // Cmd+F — filter
            showsFilter = true
            filterFieldFocused = true
            return nil
        case 2 where modifiers == [.command]:  // Cmd+D — duplicate
            duplicateSelection()
            return nil
        case 34 where modifiers == [.command]:  // Cmd+I — Get Info
            showInfoForSelection()
            return nil
        case 49 where modifiers.isEmpty:  // Space — Quick Look
            quickLookSelection()
            return nil
        case 53:  // Esc — close the filter
            guard showsFilter else { return event }
            dismissFilter()
            return nil
        default:
            return event
        }
    }

    private func moveSelection(forward: Bool, extend: Bool) {
        let rows = flatRows
        guard
            let targetID = PaneSelectionLogic.stepTarget(
                ids: rows.map(\.file.id),
                selection: selection,
                anchor: selectionAnchor,
                forward: forward
            ),
            let targetRow = rows.first(where: { $0.file.id == targetID })
        else { return }
        if extend {
            extendSelection(to: targetRow.file)
        } else {
            selectOnly(targetRow.file)
        }
        // List rows scroll by row id (path+depth), the icons grid by file id.
        keyboardScrollTarget = liveViewMode == .list ? targetRow.id : targetRow.file.id
    }

    private func selectAllVisibleItems() {
        let files = selectableFilesForCurrentView
        let state = PaneSelectionLogic.selectAll(ids: files.map(\.id))
        clearRenameState()
        selection = state.selection
        selectionAnchor = state.anchor
        if let first = files.first {
            keyboardScrollTarget = liveViewMode == .list ? "\(first.id)-0" : first.id
        }
    }

    private func openSingleSelection() {
        guard let id = singleSelection, let file = loadedFiles.first(where: { $0.id == id }) else { return }
        if canBrowseInline(file) {
            pendingSelectFirstItem = true
        }
        open(file)
    }

    private func handlePaneCommand(_ command: PaneCommand) {
        guard store.focusedPaneID == root.id, renamingFileID == nil else { return }
        switch command {
        case .newFolder:
            createFolder()
        case .newMarkdown:
            createMarkdownFile()
        case .openSelection:
            openSingleSelection()
        case .duplicateSelection:
            duplicateSelection()
        case .renameSelection:
            if let id = singleSelection, let file = loadedFiles.first(where: { $0.id == id }) {
                beginRename(file)
            }
        case .getInfo:
            showInfoForSelection()
        case .quickLook:
            quickLookSelection()
        case .readAloudSelection:
            readSelectedFileAloud()
        case .recursiveSearch:
            showRecursiveSearch()
        case .selectAll:
            selectAllVisibleItems()
        case .copySelection:
            copySelectionToPasteboard()
        case .paste:
            pasteFromPasteboard()
        case .moveToTrash:
            trashSelection()
        case .revealSelection:
            revealSelectionInFinder()
        case .compressSelection:
            compressSelection()
        }
    }

    /// Cmd+C — write the selected files' URLs to the pasteboard (Finder-compatible).
    private func copySelectionToPasteboard() {
        let urls = selectedVisibleFiles.map(\.url)
        copyURLsToPasteboard(urls)
    }

    private func copyTargetsToPasteboard(of file: BrowserFileItem) {
        copyURLsToPasteboard(actionTargets(for: file).map(\.url))
    }

    private func copyURLsToPasteboard(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects(urls as [NSURL])
        store.statusMessage = "Copied \(urls.count) item\(urls.count == 1 ? "" : "s")"
    }

    /// Cmd+V — copy files from the pasteboard into the current folder (works
    /// with files copied in Finder too). Skips files already here.
    private func pasteFromPasteboard() {
        guard let urls = NSPasteboard.general.readObjects(forClasses: [NSURL.self]) as? [URL], !urls.isEmpty else {
            return
        }
        onFocus()
        let dest = currentURL.standardizedFileURL
        for url in urls where url.deletingLastPathComponent().standardizedFileURL != dest {
            store.copy(url, toDirectory: currentURL)
        }
        scheduleReload()
    }

    private func trashSelection() {
        let targets = selectedVisibleFiles
        guard !targets.isEmpty else { return }
        for target in targets {
            store.moveToTrash(target.url)
        }
        clearSelection()
        scheduleReload()
    }

    private func setSelectedFolderExpansion(_ expand: Bool) {
        guard liveViewMode == .list, let id = singleSelection,
            let file = loadedFiles.first(where: { $0.id == id }), canBrowseInline(file)
        else { return }
        if expand, !expandedFolders.contains(file.id) {
            toggleExpansion(file)
        } else if !expand {
            expandedFolders.remove(file.id)
        }
    }

    private func duplicateSelection() {
        let targets = selectedVisibleFiles
        guard !targets.isEmpty else { return }
        for target in targets {
            store.duplicate(target.url)
        }
        scheduleReload()
    }

    private func quickLookSelection() {
        let targets = selectedVisibleFiles
        if targets.isEmpty {
            QuickLookController.shared.preview([currentURL])
        } else {
            quickLook(targets)
        }
    }

    private func quickLook(_ files: [BrowserFileItem]) {
        QuickLookController.shared.preview(files.map(\.url))
    }

    private func showInfoForSelection() {
        showInfo(for: selectedVisibleFiles.first?.url ?? currentURL)
    }

    private func showInfo(for url: URL) {
        do {
            infoSnapshot = try FileInfoService.snapshot(for: url)
        } catch {
            store.lastError = error.localizedDescription
        }
    }

    private func revealSelectionInFinder() {
        let urls = selectedVisibleFiles.map(\.url)
        NSWorkspace.shared.activateFileViewerSelecting(urls.isEmpty ? [currentURL] : urls)
    }

    private func compressSelection() {
        compressTargets(selectedVisibleFiles)
    }

    private func showRecursiveSearch() {
        onFocus()
        showsRecursiveSearch = true
    }

    private func runRecursiveSearch() {
        searchTask?.cancel()
        searchError = nil
        searchRunning = true
        let root = currentURL
        let query = searchQuery
        let includeHidden = showsHiddenItems
        searchTask = Task {
            do {
                let found = try await FileSearchService.search(in: root, query: query, includingHidden: includeHidden)
                guard !Task.isCancelled else { return }
                searchResults = found
            } catch is CancellationError {
                return
            } catch {
                searchError = error.localizedDescription
            }
            searchRunning = false
        }
    }

    private func cancelSearch() {
        searchTask?.cancel()
        searchTask = nil
        searchRunning = false
    }

    @ViewBuilder
    private var emptyAreaMenu: some View {
        Button {
            createFolder()
        } label: {
            Label("New Folder", systemImage: "folder.badge.plus")
        }

        Button {
            createMarkdownFile()
        } label: {
            Label("New MD", systemImage: "doc.badge.plus")
        }

        Button {
            onFocus()
            NSWorkspace.shared.activateFileViewerSelecting([currentURL])
        } label: {
            Label("Reveal in Finder", systemImage: "arrow.up.forward.app")
        }

        Button {
            onFocus()
            copyPath(currentURL.path)
        } label: {
            Label("Copy Path", systemImage: "doc.on.doc")
        }

        Button {
            onFocus()
            showInfo(for: currentURL)
        } label: {
            Label("Get Info", systemImage: "info.circle")
        }

        Button {
            showRecursiveSearch()
        } label: {
            Label("Search Folder…", systemImage: "magnifyingglass")
        }

        Button {
            onFocus()
            store.openTerminal(at: currentURL)
        } label: {
            Label("Open Terminal", systemImage: "terminal")
        }

        // Claude actions are opt-in (Settings ▸ Claude integration) so the
        // default menu stays focused on file management.
        if store.settings.claudeIntegrationEnabled {
            Divider()

            Button {
                onFocus()
                startAnalysis(question: ClaudeBridge.analysisPrompt, autoRun: true)
            } label: {
                Label("Analyze with Claude", systemImage: "sparkles")
            }

            Button {
                onFocus()
                startAnalysis(question: "", autoRun: false)
            } label: {
                Label("Ask Claude…", systemImage: "questionmark.bubble")
            }

            Button {
                onFocus()
                store.openClaudeCode(at: currentURL)
            } label: {
                Label("Open in Claude Code", systemImage: "apple.terminal")
            }
        }
    }

    /// Opens the Ask Claude sheet. With `autoRun` the question fires
    /// immediately (preset analysis / selection ask); otherwise the sheet
    /// waits for the user to type. Dismissing cancels the CLI process.
    private func startAnalysis(question: String, autoRun: Bool) {
        analysisQuestion = question
        analysisText = nil
        analysisError = nil
        showsAnalysis = true
        if autoRun { runAnalysis() }
    }

    private func runAnalysis() {
        analysisTask?.cancel()
        analysisText = nil
        analysisError = nil
        analysisRunning = true
        analysisTask = Task {
            do {
                let text = try await ClaudeBridge.analyzeProject(
                    at: currentURL, prompt: analysisQuestion, cliPath: store.settings.claudeCLIPath)
                analysisText = text.isEmpty ? "（Claude 没有返回内容）" : text
            } catch is CancellationError {
                // Sheet dismissed — nothing to show.
            } catch {
                analysisError = error.localizedDescription
            }
            analysisRunning = false
        }
    }

    private func askClaudeAboutSelection(_ file: BrowserFileItem) {
        onFocus()
        let targets = actionTargets(for: file)
        guard !targets.isEmpty else { return }
        let basePath = currentURL.path.hasSuffix("/") ? currentURL.path : currentURL.path + "/"
        let relativePaths = targets.map { target in
            target.url.path.hasPrefix(basePath)
                ? String(target.url.path.dropFirst(basePath.count)) : target.url.path
        }
        startAnalysis(question: ClaudeBridge.selectionPrompt(for: relativePaths), autoRun: true)
    }

    private func cancelAnalysis() {
        analysisTask?.cancel()
        analysisTask = nil
        analysisRunning = false
    }

    private func createFolder() {
        onFocus()
        guard let url = store.createFolder(in: currentURL) else { return }
        Task {
            await reloadPreservingExpansion()
            guard let item = selectLoadedFile(at: url) else { return }
            selectOnly(item)
            beginRename(item)
        }
    }

    private func createMarkdownFile() {
        onFocus()
        guard let url = store.createMarkdownFile(in: currentURL) else { return }
        Task {
            await reloadPreservingExpansion()
            _ = selectLoadedFile(at: url)
        }
    }

    private var columnContent: some View {
        ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: 0) {
                columnList(sortedItems, width: 240)

                if let selectedFolderChildren {
                    Divider()
                    columnList(selectedFolderChildren, width: 260)
                }
            }
            .frame(maxHeight: .infinity, alignment: .topLeading)
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .clipped()
    }

    private var paneToolbar: some View {
        ZStack(alignment: .topTrailing) {
            HStack(spacing: 8) {
                Button {
                    onFocus()
                    goBack()
                } label: {
                    Image(systemName: "chevron.left")
                }
                .disabled(backStack.isEmpty)
                .helpTip(store.loc("后退", "Back"))

                Button {
                    onFocus()
                    goForward()
                } label: {
                    Image(systemName: "chevron.right")
                }
                .disabled(forwardStack.isEmpty)
                .helpTip(store.loc("前进", "Forward"))

                Button {
                    onFocus()
                    goUp()
                } label: {
                    Image(systemName: "arrow.up")
                }
                .disabled(currentURL.path == "/")
                .helpTip(store.loc("上级目录", "Parent folder"))

                pathCrumbs

                Spacer(minLength: 8)

                trailingActions
                    .layoutPriority(1)
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 12)
            .frame(height: 44)
        }
        .frame(height: 44)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var trailingActions: some View {
        // Selection and view controls stay together; project status and pane
        // management remain separated so the row is easy to scan.
        HStack(spacing: 8) {
            categoryFilterButton
            viewModeButton
            readAloudMenu

            if gitSnapshot != nil {
                toolbarSeparator
                projectStatusButton
            }

            toolbarSeparator
            overflowMenu

            PaneToolbarActionButton(
                systemImage: "xmark.circle",
                accessibilityLabel: "Close Pane",
                tooltip: store.loc("关闭面板", "Close pane")
            ) {
                onFocus()
                store.removeDirectory(root)
            }
        }
    }

    private var readAloudMenu: some View {
        let selectedFile = selectedReadAloudFile
        return Menu {
            if speechController.isActive {
                if let sourceName = speechController.sourceName {
                    Text(sourceName)
                }
                if speechController.totalChunkCount > 0 {
                    Text(
                        store.loc(
                            "第 \(speechController.currentChunkNumber) / \(speechController.totalChunkCount) 段",
                            "Section \(speechController.currentChunkNumber) of \(speechController.totalChunkCount)"
                        )
                    )
                }
                Button {
                    speechController.togglePause()
                } label: {
                    Label(
                        speechController.phase == .paused
                            ? store.loc("继续", "Resume") : store.loc("暂停", "Pause"),
                        systemImage: speechController.phase == .paused ? "play.fill" : "pause.fill"
                    )
                }
                .disabled(!speechController.canPauseOrResume)

                Button {
                    speechController.restart()
                } label: {
                    Label(store.loc("从头开始", "Start Over"), systemImage: "backward.end.fill")
                }
                .disabled(speechController.phase == .loading)

                Button {
                    speechController.stop()
                } label: {
                    Label(store.loc("停止", "Stop"), systemImage: "stop.fill")
                }
                Divider()
            }

            if let selectedFile, !speechController.isReading(selectedFile.url) {
                Button {
                    startReadAloud(selectedFile)
                } label: {
                    Label(
                        store.loc("朗读 \(selectedFile.name)", "Read \(selectedFile.name)"),
                        systemImage: "speaker.wave.2"
                    )
                }
            } else if !speechController.isActive {
                Text(store.loc("请选择一个可朗读文件", "Select one readable file"))
            }

            Divider()
            Menu(store.loc("语速", "Speed")) {
                ForEach(ReadAloudSpeed.allCases) { speed in
                    Button {
                        speechController.setSpeed(speed)
                    } label: {
                        if speechController.speed == speed {
                            Label(speed.title, systemImage: "checkmark")
                        } else {
                            Text(speed.title)
                        }
                    }
                }
            }
        } label: {
            Image(systemName: speechController.phase == .paused ? "speaker.slash" : "speaker.wave.2")
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
                .foregroundStyle(speechController.isActive ? Color.accentColor : Color.secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(!speechController.isActive && selectedFile == nil)
        .helpTip(
            speechController.isActive
                ? store.loc("朗读控制", "Read aloud controls")
                : store.loc("朗读所选文件", "Read selected file")
        )
    }

    private var toolbarSeparator: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(width: 1, height: 18)
            .padding(.horizontal, 1)
    }

    private var projectStatusButton: some View {
        PaneToolbarActionButton(
            systemImage: "arrow.triangle.branch",
            accessibilityLabel: "Project Status",
            tooltip: store.loc("项目状态（git）", "Project status (git)")
        ) {
            onFocus()
            showsProjectCard = true
        }
        .popover(isPresented: $showsProjectCard, arrowEdge: .bottom) {
            if let gitSnapshot {
                ProjectStatusCard(
                    snapshot: gitSnapshot,
                    recentChanges: GitStatusService.recentChanges(in: gitSnapshot),
                    chinese: store.settings.language.isChineseResolved,
                    claudeEnabled: store.settings.claudeIntegrationEnabled,
                    onAnalyze: {
                        showsProjectCard = false
                        startAnalysis(question: ClaudeBridge.analysisPrompt, autoRun: true)
                    },
                    onOpenClaudeCode: {
                        showsProjectCard = false
                        store.openClaudeCode(at: currentURL)
                    },
                    onOpenTerminal: {
                        showsProjectCard = false
                        store.openTerminal(at: currentURL)
                    },
                    onOpenChange: { url in
                        showsProjectCard = false
                        revealRecentChange(url)
                    },
                    onShowDiff: { change in
                        showsProjectCard = false
                        showDiff(for: change, repoRoot: gitSnapshot.repoRoot)
                    }
                )
            }
        }
    }

    /// Secondary pane actions, consolidated into one "⋯" menu so the toolbar
    /// stays compact: star, hidden-items, reveal, copy path.
    private var overflowMenu: some View {
        Menu {
            Button {
                onFocus()
                store.toggleStar(currentURL)
            } label: {
                Label(
                    store.isStarred(currentURL)
                        ? store.loc("取消收藏", "Unstar") : store.loc("收藏目录", "Star folder"),
                    systemImage: store.isStarred(currentURL) ? "star.fill" : "star")
            }
            Button {
                onFocus()
                showsHiddenItems.toggle()
                Task { await reload() }
            } label: {
                Label(
                    showsHiddenItems
                        ? store.loc("隐藏隐藏文件", "Hide hidden files")
                        : store.loc("显示隐藏文件", "Show hidden files"),
                    systemImage: showsHiddenItems ? "eye.slash" : "eye")
            }
            Divider()
            Button {
                onFocus()
                NSWorkspace.shared.activateFileViewerSelecting([currentURL])
            } label: {
                Label(store.loc("在 Finder 中显示", "Reveal in Finder"), systemImage: "arrow.up.forward.app")
            }
            Button {
                onFocus()
                copyPath(currentURL.path)
            } label: {
                Label(store.loc("复制路径", "Copy Path"), systemImage: "doc.on.doc")
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
                .foregroundStyle(store.isStarred(currentURL) ? Color.accentColor : Color.secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .helpTip(store.loc("更多操作", "More actions"))
    }

    /// View mode lives in the pane's own toolbar (it is pane-local state; the
    /// old top-toolbar segmented picker implied a global switch).
    private var viewModeButton: some View {
        Menu {
            Picker("View", selection: Binding(get: { viewMode }, set: { onViewModeChange($0) })) {
                ForEach(BrowserViewMode.allCases) { mode in
                    Label(mode.title, systemImage: mode.systemImage)
                        .tag(mode)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            Image(systemName: viewMode.systemImage)
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .helpTip(store.loc("视图模式", "View mode"))
    }

    /// Category quick-filter (3-D): narrow the pane to docs / code / logs /
    /// build-and-dependency noise, etc. Rule-based, no LLM. Highlighted when
    /// active so it's obvious the listing is filtered.
    private var categoryFilterButton: some View {
        let chinese = store.settings.language.isChineseResolved
        return Menu {
            Button {
                categoryFilter = nil
            } label: {
                if categoryFilter == nil {
                    Label(store.loc("全部类型", "All types"), systemImage: "checkmark")
                } else {
                    Text(store.loc("全部类型", "All types"))
                }
            }
            Divider()
            ForEach(FileCategory.allCases) { category in
                Button {
                    categoryFilter = category
                } label: {
                    if categoryFilter == category {
                        Label(category.title(chinese: chinese), systemImage: "checkmark")
                    } else {
                        Label(category.title(chinese: chinese), systemImage: category.systemImage)
                    }
                }
            }
        } label: {
            Image(
                systemName: categoryFilter == nil
                    ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill"
            )
            .frame(width: 26, height: 26)
            .contentShape(Rectangle())
            .foregroundStyle(categoryFilter == nil ? Color.secondary : Color.accentColor)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .helpTip(
            categoryFilter == nil
                ? store.loc("按类型过滤", "Filter by type")
                : store.loc(
                    "已按「\(categoryFilter!.title(chinese: true))」过滤",
                    "Filtered: \(categoryFilter!.title(chinese: false))")
        )
    }

    private var pathCrumbs: some View {
        let all = crumbs
        let maxVisible = 4
        let truncated = all.count > maxVisible
        let shown = truncated ? Array(all.suffix(maxVisible)) : all
        let collapseTarget = truncated ? all[all.count - maxVisible - 1] : nil

        return HStack(spacing: 6) {
            if let collapseTarget {
                Button {
                    onFocus()
                    navigate(to: collapseTarget.url)
                } label: {
                    HStack(spacing: 4) {
                        Text("…")
                        Image(systemName: "chevron.right")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                .foregroundStyle(.secondary)
                .buttonStyle(.plain)
                .fixedSize()
                .help(collapseTarget.url.path)
            }

            ForEach(shown, id: \.url.path) { crumb in
                Button {
                    onFocus()
                    navigate(to: crumb.url)
                } label: {
                    HStack(spacing: 4) {
                        Text(crumb.title)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if crumb.url != shown.last?.url {
                            Image(systemName: "chevron.right")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                .foregroundStyle(.primary)
                .buttonStyle(.plain)
            }
        }
        .clipped()
    }

    private var tableHeader: some View {
        GeometryReader { proxy in
            let widths = resolvedColumnWidths(for: proxy.size.width)

            HStack(spacing: 0) {
                ResizableHeaderCell(
                    width: widths.name,
                    onResize: { phase, delta in
                        resizeColumn(.nameModified, phase: phase, delta: delta, paneWidth: proxy.size.width)
                    }
                ) {
                    SortHeaderButton(
                        title: "Name",
                        key: .name,
                        currentKey: sortKey,
                        isAscending: sortAscending,
                        action: { setSort(.name) }
                    )
                }

                ResizableHeaderCell(
                    width: widths.modified,
                    onResize: { phase, delta in
                        resizeColumn(.modifiedSize, phase: phase, delta: delta, paneWidth: proxy.size.width)
                    }
                ) {
                    SortHeaderButton(
                        title: "Modified",
                        key: .modified,
                        currentKey: sortKey,
                        isAscending: sortAscending,
                        action: { setSort(.modified) }
                    )
                }

                ResizableHeaderCell(
                    width: widths.size,
                    onResize: { phase, delta in
                        resizeColumn(.sizeKind, phase: phase, delta: delta, paneWidth: proxy.size.width)
                    }
                ) {
                    Text("Size")
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .padding(.trailing, 18)
                }

                Text("Kind")
                    .frame(width: widths.kind, height: 32, alignment: .leading)
            }
            .frame(width: proxy.size.width, height: 32, alignment: .leading)
            .clipped()
        }
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .frame(height: 32)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func resolvedColumnWidths(for paneWidth: CGFloat) -> FileListColumnWidths {
        let contentWidth = max(
            FileListColumnWidths.minName + FileListColumnWidths.minModified + FileListColumnWidths.minSize
                + FileListColumnWidths.minKind,
            paneWidth - 28
        )
        var widths = columnWidths
        widths.name = max(FileListColumnWidths.minName, widths.name)
        widths.modified = max(FileListColumnWidths.minModified, widths.modified)
        widths.size = max(FileListColumnWidths.minSize, widths.size)
        widths.kind = max(FileListColumnWidths.minKind, widths.kind)

        let total = widths.name + widths.modified + widths.size + widths.kind
        if total < contentWidth {
            widths.kind += contentWidth - total
        } else if total > contentWidth {
            shrinkColumns(&widths, by: total - contentWidth)
        }

        return widths
    }

    private func shrinkColumns(_ widths: inout FileListColumnWidths, by overflow: CGFloat) {
        var remaining = overflow

        func reduce(_ keyPath: WritableKeyPath<FileListColumnWidths, CGFloat>, minimum: CGFloat) {
            guard remaining > 0 else { return }
            let available = max(0, widths[keyPath: keyPath] - minimum)
            let reduction = min(available, remaining)
            widths[keyPath: keyPath] -= reduction
            remaining -= reduction
        }

        reduce(\.kind, minimum: FileListColumnWidths.minKind)
        reduce(\.size, minimum: FileListColumnWidths.minSize)
        reduce(\.modified, minimum: FileListColumnWidths.minModified)
        reduce(\.name, minimum: FileListColumnWidths.minName)
    }

    private func resizeColumn(_ boundary: ColumnResizeBoundary, phase: ResizePhase, delta: CGFloat, paneWidth: CGFloat)
    {
        switch phase {
        case .began:
            resizeStartWidths = resolvedColumnWidths(for: paneWidth)
        case .changed:
            guard let start = resizeStartWidths else { return }
            var updated = columnWidths

            switch boundary {
            case .nameModified:
                updated.name = max(FileListColumnWidths.minName, start.name + delta)
                updated.modified = start.modified
                updated.size = start.size
                updated.kind = start.kind
            case .modifiedSize:
                updated.name = start.name
                updated.modified = max(FileListColumnWidths.minModified, start.modified + delta)
                updated.size = start.size
                updated.kind = start.kind
            case .sizeKind:
                updated.name = start.name
                updated.modified = start.modified
                updated.size = max(FileListColumnWidths.minSize, start.size + delta)
                updated.kind = start.kind
            }

            columnWidths = updated
        case .ended:
            resizeStartWidths = nil
        }
    }

    /// Full breadcrumb chain starting at the first real path component (Users,
    /// Applications, …) — the synthetic "Macintosh HD" root is omitted.
    private var crumbs: [PathCrumb] {
        let components = currentURL.standardizedFileURL.pathComponents.filter { $0 != "/" }
        guard !components.isEmpty else {
            return [PathCrumb(url: URL(fileURLWithPath: "/"), title: "Macintosh HD", isRoot: true)]
        }
        var result: [PathCrumb] = []
        var url = URL(fileURLWithPath: "/")
        for component in components {
            url.appendPathComponent(component)
            result.append(PathCrumb(url: url, title: component, isRoot: false))
        }
        return result
    }

    private var destinations: [PaneDestination] {
        store.paneDestinations(excluding: root.id)
    }

    private var sortedItems: [BrowserFileItem] {
        sorted(visible(items))
    }

    /// Applies the text filter and the category filter together. Folders are
    /// kept when a non-folder category is selected so navigation still works.
    private func visible(_ source: [BrowserFileItem]) -> [BrowserFileItem] {
        var result = PaneFilterLogic.filter(source, query: filterText)
        if let categoryFilter {
            result = result.filter { item in
                if categoryFilter != .folder && item.isDirectory { return true }
                return FileCategoryClassifier.category(of: item) == categoryFilter
            }
        }
        return result
    }

    private var selectedFolderChildren: [BrowserFileItem]? {
        guard let selectedID = singleSelection,
            let selected = items.first(where: { $0.id == selectedID }),
            canBrowseInline(selected)
        else { return nil }
        return expandedContents[selected.id].map(sorted)
    }

    private var selectableFilesForCurrentView: [BrowserFileItem] {
        switch liveViewMode {
        case .list:
            flatRows.map(\.file)
        case .icons:
            sortedItems
        case .columns:
            sortedItems + (selectedFolderChildren ?? [])
        }
    }

    private var selectedVisibleFiles: [BrowserFileItem] {
        selectableFilesForCurrentView.filter { selection.contains($0.id) }
    }

    private var selectedReadAloudFile: BrowserFileItem? {
        guard selection.count == 1, let selectedID = selection.first else { return nil }
        if let item = items.first(where: { $0.id == selectedID }) {
            return ReadAloudFileKind.detect(item: item) == nil ? nil : item
        }
        for children in expandedContents.values {
            if let item = children.first(where: { $0.id == selectedID }) {
                return ReadAloudFileKind.detect(item: item) == nil ? nil : item
            }
        }
        return nil
    }

    private func canReadAloud(_ file: BrowserFileItem) -> Bool {
        let targetCount = selection.contains(file.id) ? selection.count : 1
        return targetCount == 1 && ReadAloudFileKind.detect(item: file) != nil
    }

    private func readSelectedFileAloud() {
        guard let file = selectedReadAloudFile else {
            store.lastError = store.loc(
                "请选择一个支持朗读的文本或 PDF 文件。",
                "Select one supported text or PDF file to read aloud."
            )
            return
        }
        startReadAloud(file)
    }

    private func startReadAloud(_ file: BrowserFileItem) {
        onFocus()
        guard canReadAloud(file), let kind = ReadAloudFileKind.detect(item: file) else {
            store.lastError = store.loc(
                "一次只能朗读一个支持的文本或 PDF 文件。",
                "Read Aloud supports one text or PDF file at a time."
            )
            return
        }
        speechController.start(url: file.url, kind: kind)
    }

    private func columnList(_ source: [BrowserFileItem], width: CGFloat) -> some View {
        LazyVStack(spacing: 0) {
            ForEach(source) { file in
                ColumnFileRow(
                    file: file,
                    isSelected: selection.contains(file.id),
                    isActivePane: isFocused,
                    canBrowseInline: canBrowseInline(file),
                    isRenaming: renamingFileID == file.id,
                    renameDraft: $renameDraft,
                    destinations: destinations,
                    select: {
                        onFocus()
                        selectOnly(file)
                    },
                    nameClick: {
                        onFocus()
                        handleNameClick(file)
                    },
                    commitRename: { commitRename(file) },
                    cancelRename: { cancelRename() },
                    rename: {
                        onFocus()
                        beginRename(file)
                    },
                    open: {
                        onFocus()
                        open(file)
                    },
                    copyFiles: {
                        onFocus()
                        copyTargetsToPasteboard(of: file)
                    },
                    copyPath: {
                        onFocus()
                        copyPath(file.url.path)
                    },
                    reveal: { NSWorkspace.shared.activateFileViewerSelecting([file.url]) },
                    trash: { trashTargets(of: file) },
                    compress: { compress(file) },
                    duplicate: { duplicateTargets(of: file) },
                    getInfo: { showInfo(for: file.url) },
                    quickLook: { quickLook(actionTargets(for: file)) },
                    canReadAloud: canReadAloud(file),
                    readAloud: { startReadAloud(file) },
                    copyTo: { destination in copyTargets(of: file, to: destination) },
                    moveTo: { destination in moveTargets(of: file, to: destination) },
                    onBeginDrag: { beginDrag(file) },
                    dropInto: { providers in dropOnFolder(file.url, providers: providers) }
                )
            }
        }
        .frame(width: width)
        .frame(maxHeight: .infinity, alignment: .topLeading)
    }

    /// Sync-context entry point for the async reloads (button actions, change
    /// handlers). Fire-and-forget; staleness is handled by `loadGeneration`.
    private func scheduleReload(selecting targetURL: URL? = nil) {
        scheduledReloadTask?.cancel()
        scheduledReloadTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            await reloadPreservingExpansion(selecting: targetURL)
            if !Task.isCancelled {
                scheduledReloadTask = nil
            }
        }
    }

    private func reload() async {
        loadGeneration += 1
        let generation = loadGeneration
        store.updatePaneLocation(id: root.id, url: currentURL)
        do {
            let loaded = try await FileBrowserService.contents(of: currentURL, includingHidden: showsHiddenItems)
            guard generation == loadGeneration else { return }
            items = loaded
            expandedFolders.removeAll()
            expandedContents.removeAll()
            stableDirectoryModificationDates = PaneFileSortLogic.directoryModificationDates(in: [loaded])
            clearRenameState()
            errorMessage = nil
            applyPostNavigationSelection()
            await refreshGitSnapshot(generation: generation)
        } catch {
            guard generation == loadGeneration else { return }
            items = []
            errorMessage = error.localizedDescription
        }
    }

    /// Keeps keyboard flow unbroken across navigation, Finder-style: going up
    /// selects the folder you came from; entering a folder via Cmd+↓ selects
    /// its first item. Without a selection, the next arrow press would start
    /// from nothing and the "cursor" would be lost.
    private func applyPostNavigationSelection() {
        if let pending = pendingSelectionURL {
            pendingSelectionURL = nil
            if let file = selectLoadedFile(at: pending) {
                keyboardScrollTarget = liveViewMode == .list ? "\(file.id)-0" : file.id
                return
            }
        }
        if pendingSelectFirstItem {
            pendingSelectFirstItem = false
            if let first = sortedItems.first {
                selectOnly(first)
                keyboardScrollTarget = liveViewMode == .list ? "\(first.id)-0" : first.id
            }
        }
    }

    /// Fetched after the file list is already on screen, so git never delays
    /// showing files; the generation guard drops stale results.
    private func refreshGitSnapshot(generation: Int) async {
        let snapshot = await GitStatusService.snapshot(for: currentURL)
        guard generation == loadGeneration else { return }
        gitSnapshot = snapshot
    }

    private func reloadPreservingExpansion(selecting targetURL: URL? = nil) async {
        loadGeneration += 1
        let generation = loadGeneration
        store.updatePaneLocation(id: root.id, url: currentURL)
        do {
            let loaded = try await FileBrowserService.contents(of: currentURL, includingHidden: showsHiddenItems)
            var reloadedContents: [String: [BrowserFileItem]] = [:]
            for folderID in expandedFolders {
                let folderURL = URL(fileURLWithPath: folderID)
                reloadedContents[folderID] = try? await FileBrowserService.contents(
                    of: folderURL,
                    includingHidden: showsHiddenItems
                )
            }
            guard generation == loadGeneration else { return }
            items = loaded
            for (folderID, contents) in reloadedContents {
                expandedContents[folderID] = contents
            }
            stableDirectoryModificationDates = PaneFileSortLogic.mergedDirectoryModificationDates(
                existing: stableDirectoryModificationDates,
                groups: [loaded] + Array(reloadedContents.values)
            )
            if let targetURL, selectLoadedFile(at: targetURL) != nil {
                pendingSelectionURL = nil
            }
            errorMessage = nil
            await refreshGitSnapshot(generation: generation)
        } catch {
            guard generation == loadGeneration else { return }
            items = []
            errorMessage = error.localizedDescription
        }
    }

    private var flatRows: [PaneVisibleRow] {
        PaneVisibleRowLogic.flatten(
            sortedItems,
            expandedFolderIDs: expandedFolders,
            expandedContents: expandedContents,
            canBrowseInline: canBrowseInline,
            sortAndFilterChildren: { sorted(visible($0)) }
        )
    }

    // Sort lives in the store (keyed by pane id) so it survives workspace
    // switches that destroy and recreate panes.
    private var sortKey: BrowserSortKey { store.paneSortOrder(for: root.id).key }
    private var sortAscending: Bool { store.paneSortOrder(for: root.id).ascending }

    private func setSort(_ key: BrowserSortKey) {
        var order = store.paneSortOrder(for: root.id)
        if order.key == key {
            order.ascending.toggle()
        } else {
            order.key = key
            order.ascending = key.defaultAscending
        }
        store.setPaneSortOrder(order, for: root.id)
        stableDirectoryModificationDates = PaneFileSortLogic.directoryModificationDates(in: [loadedFiles])
    }

    private func sorted(_ source: [BrowserFileItem]) -> [BrowserFileItem] {
        PaneFileSortLogic.sort(
            source,
            key: sortKey,
            ascending: sortAscending,
            stableDirectoryModificationDates: stableDirectoryModificationDates
        )
    }

    private func toggleExpansion(_ file: BrowserFileItem) {
        guard canBrowseInline(file) else { return }
        if expandedFolders.contains(file.id) {
            expandedFolders.remove(file.id)
            return
        }

        Task {
            do {
                let children = try await FileBrowserService.contents(
                    of: file.url, includingHidden: showsHiddenItems)
                expandedContents[file.id] = children
                stableDirectoryModificationDates = PaneFileSortLogic.mergedDirectoryModificationDates(
                    existing: stableDirectoryModificationDates,
                    groups: [items, children]
                )
                expandedFolders.insert(file.id)
            } catch {
                store.lastError = error.localizedDescription
            }
        }
    }

    /// The single selected item, or nil when zero or multiple are selected.
    /// Rename and column drill-down only act on a single selection.
    private var singleSelection: BrowserFileItem.ID? {
        selection.count == 1 ? selection.first : nil
    }

    private func clearSelection() {
        selection = []
        selectionAnchor = nil
        // Navigation calls this; a stale filter from the previous folder would
        // silently hide files in the new one.
        filterText = ""
        categoryFilter = nil
    }

    /// Routes a row click through the active modifier keys: Shift extends a
    /// contiguous range from the anchor, Command/Option toggles one item, a plain
    /// click selects only that item.
    private func handleRowTap(_ file: BrowserFileItem) {
        let modifiers = NSEvent.modifierFlags
        if modifiers.contains(.shift) {
            extendSelection(to: file)
        } else if modifiers.contains(.command) || modifiers.contains(.option) {
            toggleSelection(file)
        } else {
            selectOnly(file)
        }
    }

    private func selectOnly(_ file: BrowserFileItem) {
        if selection != [file.id] {
            cancelPendingRename()
        }
        selection = [file.id]
        selectionAnchor = file.id
        if renamingFileID != file.id {
            renamingFileID = nil
        }
        prepareColumnDrillDown(file)
    }

    @discardableResult
    private func selectLoadedFile(at url: URL) -> BrowserFileItem? {
        let targetPath = url.standardizedFileURL.path
        guard let file = loadedFiles.first(where: { $0.url.standardizedFileURL.path == targetPath }) else {
            return nil
        }
        cancelPendingRename()
        selection = [file.id]
        selectionAnchor = file.id
        renamingFileID = nil
        prepareColumnDrillDown(file)
        return file
    }

    private var loadedFiles: [BrowserFileItem] {
        items + expandedContents.values.flatMap { $0 }
    }

    private func toggleSelection(_ file: BrowserFileItem) {
        cancelPendingRename()
        renamingFileID = nil
        if selection.contains(file.id) {
            selection.remove(file.id)
        } else {
            selection.insert(file.id)
        }
        selectionAnchor = file.id
    }

    private func extendSelection(to file: BrowserFileItem) {
        cancelPendingRename()
        renamingFileID = nil
        let rows = flatRows
        let anchorID = selectionAnchor ?? selection.first
        guard let anchorID,
            let anchorIndex = rows.firstIndex(where: { $0.file.id == anchorID }),
            let targetIndex = rows.firstIndex(where: { $0.file.id == file.id })
        else {
            selection = [file.id]
            selectionAnchor = file.id
            return
        }
        let range = anchorIndex <= targetIndex ? anchorIndex...targetIndex : targetIndex...anchorIndex
        selection = Set(rows[range].map(\.file.id))
        // Keep the anchor so a subsequent Shift-click re-extends from the same origin.
    }

    private func prepareColumnDrillDown(_ file: BrowserFileItem) {
        guard liveViewMode == .columns, canBrowseInline(file) else { return }
        guard expandedContents[file.id] == nil else { return }
        Task {
            let children = try? await FileBrowserService.contents(
                of: file.url, includingHidden: showsHiddenItems)
            if expandedContents[file.id] == nil {
                expandedContents[file.id] = children
            }
        }
    }

    private func handleNameClick(_ file: BrowserFileItem) {
        // When a selection modifier is held, let the row's tap gesture own the
        // multi-select (Command toggle / Shift range). Doing selection here too
        // would run alongside it and collapse the result back to a single item.
        let modifiers = NSEvent.modifierFlags
        if modifiers.contains(.command) || modifiers.contains(.option) || modifiers.contains(.shift) {
            return
        }
        guard singleSelection == file.id, isFocused else {
            selectOnly(file)
            return
        }
        scheduleRename(file)
    }

    private func scheduleRename(_ file: BrowserFileItem) {
        cancelPendingRename()
        pendingRenameTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(1_150))
            guard !Task.isCancelled,
                selection == [file.id],
                isFocused,
                renamingFileID == nil
            else { return }
            beginRename(file)
        }
    }

    private func cancelPendingRename() {
        pendingRenameTask?.cancel()
        pendingRenameTask = nil
    }

    private func clearRenameState() {
        cancelPendingRename()
        renamingFileID = nil
        renameDraft = ""
    }

    private func beginRename(_ file: BrowserFileItem) {
        cancelPendingRename()
        selection = [file.id]
        selectionAnchor = file.id
        renameDraft = file.name
        renamingFileID = file.id
    }

    /// Files to act on for a row context-menu action: the whole selection when
    /// the right-clicked row is part of it, otherwise just that row.
    private func actionTargets(for file: BrowserFileItem) -> [BrowserFileItem] {
        let ids = selection.contains(file.id) ? selection : [file.id]
        return flatRows.map(\.file).filter { ids.contains($0.id) }
    }

    // Row context-menu actions operate on the whole selection (or just the
    // right-clicked row when it isn't part of it). Each routes through
    // actionTargets so multi-select doesn't silently act on one file.

    private func trashTargets(of file: BrowserFileItem) {
        for target in actionTargets(for: file) {
            store.moveToTrash(target.url)
        }
        scheduleReload()
    }

    private func copyTargets(of file: BrowserFileItem, to destination: PaneDestination) {
        for target in actionTargets(for: file) {
            store.copy(target.url, to: destination)
        }
        scheduleReload()
    }

    private func moveTargets(of file: BrowserFileItem, to destination: PaneDestination) {
        for target in actionTargets(for: file) {
            store.move(target.url, to: destination)
        }
        scheduleReload()
    }

    private func duplicateTargets(of file: BrowserFileItem) {
        for target in actionTargets(for: file) {
            store.duplicate(target.url)
        }
        scheduleReload()
    }

    private func compress(_ file: BrowserFileItem) {
        onFocus()
        compressTargets(actionTargets(for: file))
    }

    private func compressTargets(_ targets: [BrowserFileItem]) {
        guard !targets.isEmpty else { return }
        // Output goes in the directory of the shallowest selected item, and the
        // default archive name follows that containing folder instead of the
        // pane root. This matches Finder-like behavior for expanded subfolders.
        let shallowest = targets.min { lhs, rhs in
            lhs.url.pathComponents.count < rhs.url.pathComponents.count
        }
        let outputDirectory = (shallowest ?? targets[0]).url.deletingLastPathComponent()
        let baseName = outputDirectory.lastPathComponent.isEmpty ? "Archive" : outputDirectory.lastPathComponent
        pendingSelectionURL = store.compress(
            targets.map(\.url),
            relativeTo: outputDirectory,
            archiveName: baseName,
            into: outputDirectory
        )
        // The new archive appears once zip finishes; the resulting
        // fileOperationRevision bump triggers a reload (see .onChange in body).
    }

    private func commitRename(_ file: BrowserFileItem) {
        store.renameFile(file.url, to: renameDraft)
        clearRenameState()
        scheduleReload()
    }

    private func cancelRename() {
        clearRenameState()
    }

    /// Records the whole selection (or just `file` when it isn't selected) as
    /// the in-app drag payload, so dropping moves every dragged file.
    private func beginDrag(_ file: BrowserFileItem) {
        let ids = selection.contains(file.id) ? selection : [file.id]
        store.dragPayload = loadedFiles.filter { ids.contains($0.id) }.map(\.url)
    }

    /// Drop on the pane's empty area. An in-app drag dropped here does nothing
    /// (Finder-style: you move files by dropping ONTO a folder, not into empty
    /// space) — so a drag released in place never relocates the file. External
    /// drags (from Finder) drop into the current folder.
    private func dropOnPaneBackground(_ providers: [NSItemProvider]) -> Bool {
        if !store.dragPayload.isEmpty {
            store.dragPayload = []
            return false
        }
        return handleExternalDrop(providers, into: currentURL)
    }

    /// Drop onto a folder row. In-app drags move the whole payload into the
    /// folder; external drags move the providers in. Files already in the
    /// destination are skipped (dropping a folder onto itself / a file onto its
    /// own folder is a no-op, never a duplicate).
    @discardableResult
    private func dropOnFolder(_ destination: URL, providers: [NSItemProvider]) -> Bool {
        let payload = store.dragPayload
        if !payload.isEmpty {
            store.dragPayload = []
            let dest = destination.standardizedFileURL
            let targets = payload.filter { url in
                url.standardizedFileURL != dest
                    && url.deletingLastPathComponent().standardizedFileURL != dest
            }
            guard !targets.isEmpty else { return false }
            onFocus()
            for url in targets { store.move(url, toDirectory: destination) }
            scheduleReload()
            return true
        }
        return handleExternalDrop(providers, into: destination)
    }

    private func handleExternalDrop(_ providers: [NSItemProvider], into destination: URL) -> Bool {
        let fileProviders = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        guard !fileProviders.isEmpty else { return false }

        for provider in fileProviders {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                guard let sourceURL = droppedFileURL(from: item) else { return }
                Task { @MainActor in
                    onFocus()
                    store.move(sourceURL, toDirectory: destination)
                    scheduleReload()
                }
            }
        }
        return true
    }

    nonisolated private func droppedFileURL(from item: NSSecureCoding?) -> URL? {
        if let url = item as? URL {
            return url
        }
        if let data = item as? Data,
            let value = String(data: data, encoding: .utf8)
        {
            return URL(string: value)
        }
        if let value = item as? String {
            return URL(string: value)
        }
        return nil
    }

    private func open(_ file: BrowserFileItem) {
        clearRenameState()
        if canBrowseInline(file) {
            navigate(to: file.url)
        } else if MarkdownFileService.isMarkdownURL(file.url) {
            openWindow(value: MarkdownWindowRequest(url: file.url))
        } else {
            NSWorkspace.shared.open(file.url)
        }
    }

    private func navigate(to url: URL) {
        onFocus()
        guard url != currentURL else { return }
        clearRenameState()
        backStack.append(currentURL)
        forwardStack.removeAll()
        currentURL = url
        clearSelection()
    }

    private func goBack() {
        guard let previous = backStack.popLast() else { return }
        forwardStack.append(currentURL)
        currentURL = previous
        clearSelection()
    }

    private func goForward() {
        guard let next = forwardStack.popLast() else { return }
        backStack.append(currentURL)
        currentURL = next
        clearSelection()
    }

    /// Loads and shows `git diff` for one changed file in a sheet.
    private func showDiff(for change: RecentChange, repoRoot: URL) {
        diffFileName = change.url.lastPathComponent
        diffLines = []
        diffLoading = true
        showsDiff = true
        diffTask?.cancel()
        diffTask = Task {
            let output = await GitStatusService.diff(
                for: change.url, repoRoot: repoRoot, status: change.status)
            if Task.isCancelled { return }
            diffLines = GitStatusService.parseDiff(output ?? "")
            diffLoading = false
        }
    }

    /// Hands the currently-shown diff to Claude for an explanation (3-F):
    /// closes the diff sheet and opens the analysis sheet with the diff inlined
    /// as context, so Claude reasons about the actual edit.
    private func explainCurrentDiff() {
        let diffText = diffLines.map(\.text).joined(separator: "\n")
        let prompt = ClaudeBridge.explainDiffPrompt(fileName: diffFileName, diff: diffText)
        showsDiff = false
        // Let the diff sheet finish dismissing before presenting the analysis
        // sheet — SwiftUI drops the second present if they overlap in one tick.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(250))
            startAnalysis(question: prompt, autoRun: true)
        }
    }

    /// Jumps the pane to a recently-changed file: navigate to its parent
    /// folder (if not already there), then select it once loaded.
    private func revealRecentChange(_ url: URL) {
        onFocus()
        let parent = url.deletingLastPathComponent()
        if parent.standardizedFileURL != currentURL.standardizedFileURL {
            pendingSelectionURL = url
            navigate(to: parent)
        } else {
            _ = selectLoadedFile(at: url)
            keyboardScrollTarget = liveViewMode == .list ? "\(url.path)-0" : url.path
        }
    }

    private func goUp() {
        // Guard here (not just at the disabled toolbar button) because the
        // keyboard shortcut and empty-area double-click also land here.
        guard currentURL.path != "/" else { return }
        // Finder-style: after going up, the folder we came from is selected.
        let origin = currentURL
        navigate(to: currentURL.deletingLastPathComponent())
        pendingSelectionURL = origin
    }

    private func copyPath(_ path: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
        store.statusMessage = "Copied path"
    }

    private func canBrowseInline(_ file: BrowserFileItem) -> Bool {
        file.canBrowseInline(showHiddenItems: showsHiddenItems)
    }
}

private struct PathCrumb: Hashable {
    let url: URL
    let title: String
    let isRoot: Bool
}

private struct SortHeaderButton: View {
    let title: String
    let key: BrowserSortKey
    let currentKey: BrowserSortKey
    let isAscending: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(title)
                if currentKey == key {
                    Image(systemName: isAscending ? "chevron.up" : "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                }
                Spacer(minLength: 0)
            }
            .frame(maxHeight: .infinity, alignment: .center)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(currentKey == key ? .primary : .secondary)
        .help("Sort by \(title)")
    }
}

/// Paints the alternating-row tint for the blank region beneath the last file,
/// continuing the parity from `startIndex`. Sized by its caller to at most the
/// viewport height, so the drawing stays bounded regardless of folder size.
private struct ListStripeFiller: View {
    let startIndex: Int

    var body: some View {
        Canvas { context, size in
            let rowHeight = FileRowMetrics.height
            let color = FileRowMetrics.alternateRowColor
            var band = 0
            var y: CGFloat = 0
            while y < size.height {
                if !(startIndex + band).isMultiple(of: 2) {
                    let rect = CGRect(x: 0, y: y, width: size.width, height: min(rowHeight, size.height - y))
                    context.fill(Path(rect), with: .color(color))
                }
                band += 1
                y = CGFloat(band) * rowHeight
            }
        }
        .allowsHitTesting(false)
    }
}

private enum ColumnResizeBoundary {
    case nameModified
    case modifiedSize
    case sizeKind
}

private struct ResizableHeaderCell<Content: View>: View {
    let width: CGFloat
    let onResize: (ResizePhase, CGFloat) -> Void
    @ViewBuilder let content: () -> Content
    @State private var didBeginDrag = false

    var body: some View {
        content()
            .frame(width: width, height: 32, alignment: .center)
            .overlay(alignment: .trailing) {
                Rectangle()
                    .fill(Color(nsColor: .separatorColor))
                    .frame(width: 1, height: 32)
                    .frame(width: 10, height: 32)
                    .contentShape(Rectangle())
                    .columnResizeCursor()
                    .gesture(
                        // Global coordinate space: the handle moves as the
                        // column resizes, so a view-local translation would
                        // feed back on itself and jitter the next column.
                        DragGesture(minimumDistance: 0, coordinateSpace: .global)
                            .onChanged { value in
                                if !didBeginDrag {
                                    didBeginDrag = true
                                    onResize(.began, 0)
                                }
                                onResize(.changed, value.translation.width)
                            }
                            .onEnded { _ in
                                didBeginDrag = false
                                onResize(.ended, 0)
                            }
                    )
            }
    }
}
