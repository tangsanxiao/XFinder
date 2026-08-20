import AppKit
import CoreGraphics
import ImageIO
import SwiftUI

private enum MarkdownViewMode: String, CaseIterable, Identifiable {
    case preview
    case edit
    case split

    var id: String { rawValue }
}

struct MarkdownDocumentView: View {
    @EnvironmentObject private var store: WorkspaceStore
    @EnvironmentObject private var speechController: ReadAloudController
    @StateObject private var document: MarkdownDocumentController
    @State private var mode = MarkdownViewMode.preview
    @State private var showsReloadConfirmation = false
    @State private var showsSearch = false
    @State private var pendingSibling: MarkdownSiblingFile?
    @State private var didCopyRichText = false

    init(url: URL) {
        _document = StateObject(wrappedValue: MarkdownDocumentController(url: url))
    }

    var body: some View {
        Group {
            switch document.phase {
            case .loading:
                ProgressView(store.loc("正在读取…", "Loading…"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let message):
                errorView(message)
            case .ready:
                documentSurface
            }
        }
        .frame(minWidth: 760, minHeight: 540)
        .navigationTitle(document.url.lastPathComponent)
        .toolbar { documentToolbar }
        .task {
            document.onStatus = { [weak store] message, isError in
                if isError {
                    store?.lastError = message
                } else {
                    store?.statusMessage = message
                }
            }
            await document.load()
        }
        .task(id: document.url) {
            await watchOpenedDocument(at: document.url)
        }
        .onDisappear {
            Task { _ = await document.save() }
        }
        .onChange(of: document.isEditable) { isEditable in
            if !isEditable { mode = .preview }
        }
        .alert(store.loc("文件已在外部修改", "File Changed Externally"), isPresented: conflictBinding) {
            Button(store.loc("重新载入", "Reload"), role: .destructive) {
                document.reloadDiscardingChanges()
            }
            Button(store.loc("覆盖文件", "Overwrite")) {
                document.overwriteExternalChanges()
            }
            Button(store.loc("取消", "Cancel"), role: .cancel) {
                document.cancelConflictPrompt()
            }
        } message: {
            Text(
                store.loc(
                    "磁盘上的文件比当前编辑内容更新。重新载入会丢弃本窗口的修改，覆盖会替换磁盘版本。",
                    "The file on disk is newer than this editor. Reload discards this window's edits; Overwrite replaces the disk version."
                )
            )
        }
        .confirmationDialog(
            store.loc("重新载入并丢弃当前修改？", "Reload and discard current edits?"),
            isPresented: $showsReloadConfirmation
        ) {
            Button(store.loc("重新载入", "Reload"), role: .destructive) {
                document.reloadDiscardingChanges()
            }
        }
        .confirmationDialog(
            store.loc("切换文档前处理当前修改", "Handle edits before switching documents"),
            isPresented: pendingSiblingBinding
        ) {
            Button(store.loc("保存并切换", "Save and Switch")) {
                guard let pendingSibling else { return }
                Task {
                    guard await document.save() else { return }
                    _ = await document.openSibling(pendingSibling)
                    self.pendingSibling = nil
                }
            }
            Button(store.loc("丢弃并切换", "Discard and Switch"), role: .destructive) {
                guard let pendingSibling else { return }
                Task {
                    _ = await document.openSibling(pendingSibling, discardingChanges: true)
                    self.pendingSibling = nil
                }
            }
            Button(store.loc("取消", "Cancel"), role: .cancel) {
                pendingSibling = nil
            }
        }
    }

    @ToolbarContentBuilder
    private var documentToolbar: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            if document.isEditable {
                Picker(store.loc("显示模式", "View mode"), selection: $mode) {
                    Text(store.loc("阅读", "Preview")).tag(MarkdownViewMode.preview)
                    Text(store.loc("编辑", "Edit")).tag(MarkdownViewMode.edit)
                    Text(store.loc("分屏", "Split")).tag(MarkdownViewMode.split)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 210)
            } else {
                Label(store.loc("只读", "Read-only"), systemImage: "eye")
                    .foregroundStyle(.secondary)
            }
        }

        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                showsSearch.toggle()
            } label: {
                Image(systemName: "magnifyingglass")
            }
            .help(store.loc("搜索文档", "Search document"))
            .keyboardShortcut("f", modifiers: .command)

            Button {
                Task { _ = await document.save() }
            } label: {
                Image(systemName: "square.and.arrow.down")
            }
            .disabled(!document.isDirty || document.isSaving)
            .help(store.loc("保存", "Save"))
            .keyboardShortcut("s", modifiers: .command)

            Button {
                if document.isDirty {
                    showsReloadConfirmation = true
                } else {
                    document.reloadDiscardingChanges()
                }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help(store.loc("重新载入", "Reload"))

            Button {
                toggleReadAloud()
            } label: {
                Image(systemName: speechController.isReading(document.url) ? "stop.fill" : "speaker.wave.2")
            }
            .foregroundStyle(speechController.isReading(document.url) ? Color.accentColor : Color.primary)
            .help(
                speechController.isReading(document.url)
                    ? store.loc("停止朗读", "Stop reading")
                    : store.loc("朗读文档", "Read document aloud")
            )

            Button {
                copyRichText()
            } label: {
                Image(systemName: didCopyRichText ? "checkmark.circle.fill" : "doc.on.clipboard")
            }
            .foregroundStyle(didCopyRichText ? Color.accentColor : Color.primary)
            .help(store.loc("复制为富文本，可粘贴到邮件或文档", "Copy as rich text for email or documents"))

            Menu {
                Button(store.loc("插入 Markdown 语法速查", "Insert Markdown Syntax Cheatsheet")) {
                    document.insertCheatsheet()
                    mode = .edit
                    store.statusMessage = store.loc("已插入 Markdown 速查", "Inserted Markdown cheatsheet")
                }
                Divider()
                ForEach(MarkdownTemplate.allCases) { template in
                    Button(templateTitle(template)) {
                        document.insertTemplate(template)
                        mode = .edit
                        store.statusMessage = insertedTemplateMessage(template)
                    }
                }
                Divider()
                Button(store.loc("导出 PDF…", "Export PDF…")) {
                    exportPDF()
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .help(store.loc("插入模板、速查或导出 PDF", "Insert templates, cheatsheet, or export PDF"))

            Button {
                NSWorkspace.shared.open(document.url)
            } label: {
                Image(systemName: "arrow.up.right.square")
            }
            .help(store.loc("使用默认应用打开", "Open with default app"))
        }
    }

    private var documentSurface: some View {
        VStack(spacing: 0) {
            if showsSearch {
                searchBar
            }

            Group {
                if document.siblings.count > 1 {
                    HSplitView {
                        siblingSidebar
                            .frame(minWidth: 150, idealWidth: 190, maxWidth: 240)
                        documentBody
                            .frame(minWidth: 560)
                    }
                } else {
                    documentBody
                }
            }

            Divider()

            HStack(spacing: 8) {
                if document.isDirty {
                    Circle()
                        .fill(Color.orange)
                        .frame(width: 7, height: 7)
                } else {
                    Image(systemName: "checkmark.circle")
                        .foregroundStyle(.secondary)
                }
                Text(store.loc(statusTextChinese, document.statusText))
                    .lineLimit(1)
                Spacer()
                if case .active = document.agentActivity {
                    Label(store.loc("外部更新", "External update"), systemImage: "bolt.horizontal.circle.fill")
                        .foregroundStyle(Color.accentColor)
                }
                Text("\(document.source.count.formatted()) \(store.loc("字符", "characters"))")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14)
            .frame(height: 26)
            .background(Color(nsColor: .controlBackgroundColor))
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    @ViewBuilder
    private var documentBody: some View {
        switch mode {
        case .preview:
            MarkdownPreviewView(
                document: document.rendered,
                sourceURL: document.url,
                searchQuery: document.searchQuery,
                highlightedBlockIDs: document.highlightedBlockIDs,
                onToggleTask: { document.toggleTask(ordinal: $0) }
            )
        case .edit:
            MarkdownEditorView(source: sourceBinding)
        case .split:
            HSplitView {
                MarkdownEditorView(source: sourceBinding)
                    .frame(minWidth: 300)
                MarkdownPreviewView(
                    document: document.rendered,
                    sourceURL: document.url,
                    searchQuery: document.searchQuery,
                    highlightedBlockIDs: document.highlightedBlockIDs,
                    onToggleTask: { document.toggleTask(ordinal: $0) }
                )
                .frame(minWidth: 340)
            }
        }
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField(store.loc("搜索当前 Markdown", "Search current Markdown"), text: searchBinding)
                .textFieldStyle(.plain)
            Text("\(document.searchMatchCount)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .frame(minWidth: 30, alignment: .trailing)
            Button {
                document.updateSearchQuery("")
                showsSearch = false
            } label: {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help(store.loc("关闭搜索", "Close search"))
        }
        .padding(.horizontal, 12)
        .frame(height: 34)
        .background(Color(nsColor: .controlBackgroundColor))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color(nsColor: .separatorColor))
                .frame(height: 1)
        }
    }

    private var siblingSidebar: some View {
        List(document.siblings) { sibling in
            Button {
                openSibling(sibling)
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: sibling.url == document.url ? "doc.text.fill" : "doc.text")
                        .foregroundStyle(sibling.url == document.url ? Color.accentColor : Color.secondary)
                    Text(sibling.name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .listRowBackground(sibling.url == document.url ? Color.accentColor.opacity(0.12) : Color.clear)
        }
        .listStyle(.sidebar)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var sourceBinding: Binding<String> {
        Binding(get: { document.source }, set: { document.updateSource($0) })
    }

    private var searchBinding: Binding<String> {
        Binding(get: { document.searchQuery }, set: { document.updateSearchQuery($0) })
    }

    private var conflictBinding: Binding<Bool> {
        Binding(
            get: { document.hasExternalConflict },
            set: { if !$0 { document.cancelConflictPrompt() } }
        )
    }

    private var pendingSiblingBinding: Binding<Bool> {
        Binding(
            get: { pendingSibling != nil },
            set: { if !$0 { pendingSibling = nil } }
        )
    }

    private var statusTextChinese: String {
        switch document.statusText {
        case "Loading…": return "正在读取…"
        case "Saved": return "已保存"
        case "Edited": return "已修改"
        case "Saving…": return "正在保存…"
        case "Changed externally": return "文件已在外部修改"
        case "Save failed": return "保存失败"
        case "Read-only · file exceeds the editing limit": return "只读 · 文件超过编辑上限"
        default: return document.statusText
        }
    }

    private func openSibling(_ sibling: MarkdownSiblingFile) {
        if document.isDirty {
            pendingSibling = sibling
        } else {
            Task { _ = await document.openSibling(sibling) }
        }
    }

    private func toggleReadAloud() {
        if speechController.isReading(document.url) {
            speechController.stop()
        } else {
            Task {
                guard await document.save() else { return }
                speechController.start(url: document.url, kind: .markdown)
            }
        }
    }

    private func copyRichText() {
        if document.copyRichTextToPasteboard() {
            didCopyRichText = true
            store.statusMessage = store.loc("已复制 Markdown 富文本", "Copied Markdown rich text")
            Task {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                didCopyRichText = false
            }
        } else {
            store.lastError = store.loc("复制 Markdown 富文本失败", "Copy Markdown rich text failed")
        }
    }

    private func templateTitle(_ template: MarkdownTemplate) -> String {
        switch template {
        case .note: return store.loc("插入笔记模板", "Insert Note Template")
        case .meeting: return store.loc("插入会议模板", "Insert Meeting Template")
        case .research: return store.loc("插入研究模板", "Insert Research Template")
        }
    }

    private func insertedTemplateMessage(_ template: MarkdownTemplate) -> String {
        switch template {
        case .note: return store.loc("已插入笔记模板", "Inserted note template")
        case .meeting: return store.loc("已插入会议模板", "Inserted meeting template")
        case .research: return store.loc("已插入研究模板", "Inserted research template")
        }
    }

    private func exportPDF() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = document.url.deletingPathExtension().lastPathComponent + ".pdf"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try document.exportPDF(to: url)
        } catch {
            store.lastError = store.loc(
                "导出 PDF 失败：\(error.localizedDescription)",
                "Export PDF failed: \(error.localizedDescription)"
            )
        }
    }

    private func watchOpenedDocument(at url: URL) async {
        let directory = url.deletingLastPathComponent()
        for await _ in DirectoryWatcher.changes(of: directory) {
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            await document.handleExternalChange()
        }
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 34))
                .foregroundStyle(.secondary)
            Text(store.loc("无法打开 Markdown", "Cannot Open Markdown"))
                .font(.headline)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
            Button {
                NSWorkspace.shared.open(document.url)
            } label: {
                Label(store.loc("使用默认应用打开", "Open with default app"), systemImage: "arrow.up.right.square")
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct MarkdownEditorView: View {
    @Binding var source: String

    var body: some View {
        TextEditor(text: $source)
            .font(.system(size: 13, design: .monospaced))
            .lineSpacing(3)
            .scrollContentBackground(.hidden)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color(nsColor: .textBackgroundColor))
    }
}

private struct MarkdownPreviewView: View {
    @EnvironmentObject private var store: WorkspaceStore
    let document: MarkdownRenderDocument
    let sourceURL: URL
    let searchQuery: String
    let highlightedBlockIDs: Set<Int>
    let onToggleTask: (Int) -> Void

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                if document.wasTruncated {
                    Label(
                        store.loc("为保证性能，预览内容已限制", "Preview limited for performance"),
                        systemImage: "gauge.with.dots.needle.33percent"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 4)
                }

                ForEach(document.blocks) { block in
                    MarkdownBlockView(
                        block: block,
                        sourceURL: sourceURL,
                        searchQuery: searchQuery,
                        highlightedBlockIDs: highlightedBlockIDs,
                        onToggleTask: onToggleTask
                    )
                }

                if document.blocks.isEmpty {
                    Text(store.loc("空 Markdown 文档", "Empty Markdown document"))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 180, alignment: .center)
                }
            }
            .frame(maxWidth: 860, alignment: .leading)
            .padding(.horizontal, 34)
            .padding(.vertical, 28)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .background(Color(nsColor: .textBackgroundColor))
        .textSelection(.enabled)
    }
}

struct MarkdownBlockView: View {
    let block: MarkdownBlockModel
    let sourceURL: URL
    let searchQuery: String
    let highlightedBlockIDs: Set<Int>
    let onToggleTask: (Int) -> Void

    @ViewBuilder
    var body: some View {
        blockContent
            .padding(.horizontal, 4)
            .padding(.vertical, 3)
            .background(blockHighlight)
            .clipShape(RoundedRectangle(cornerRadius: 5))
    }

    @ViewBuilder
    private var blockContent: some View {
        switch block.kind {
        case .heading(let level, let runs):
            MarkdownInlineText(runs: runs, sourceURL: sourceURL)
                .font(headingFont(level))
                .foregroundStyle(level > 4 ? Color.secondary : Color.primary)
                .padding(.top, level <= 2 ? 8 : 2)
        case .paragraph(let runs):
            MarkdownInlineText(runs: runs, sourceURL: sourceURL)
                .font(.system(size: 15))
                .lineSpacing(5)
                .fixedSize(horizontal: false, vertical: true)
        case .blockQuote(let blocks):
            HStack(alignment: .top, spacing: 12) {
                Rectangle()
                    .fill(Color.secondary.opacity(0.45))
                    .frame(width: 3)
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(blocks) { nested in
                        MarkdownBlockView(
                            block: nested,
                            sourceURL: sourceURL,
                            searchQuery: searchQuery,
                            highlightedBlockIDs: highlightedBlockIDs,
                            onToggleTask: onToggleTask
                        )
                    }
                }
                .foregroundStyle(.secondary)
            }
        case .code(let language, let text):
            VStack(alignment: .leading, spacing: 6) {
                if let language, !language.isEmpty {
                    Text(language.uppercased())
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                ScrollView(.horizontal) {
                    Text(text)
                        .font(.system(size: 13, design: .monospaced))
                        .fixedSize(horizontal: true, vertical: true)
                        .padding(12)
                }
                .background(Color(nsColor: .controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        case .unorderedList(let items):
            MarkdownListView(
                items: items,
                start: nil,
                sourceURL: sourceURL,
                searchQuery: searchQuery,
                highlightedBlockIDs: highlightedBlockIDs,
                onToggleTask: onToggleTask
            )
        case .orderedList(let start, let items):
            MarkdownListView(
                items: items,
                start: start,
                sourceURL: sourceURL,
                searchQuery: searchQuery,
                highlightedBlockIDs: highlightedBlockIDs,
                onToggleTask: onToggleTask
            )
        case .thematicBreak:
            Divider()
                .padding(.vertical, 6)
        case .table(let table):
            MarkdownTableView(table: table, sourceURL: sourceURL)
        case .image(let image):
            MarkdownLocalImageView(model: image, sourceURL: sourceURL)
        }
    }

    @ViewBuilder
    private var blockHighlight: some View {
        if highlightedBlockIDs.contains(block.id) {
            Color.accentColor.opacity(0.12)
        } else if blockMatchesSearch {
            Color.yellow.opacity(0.16)
        } else {
            Color.clear
        }
    }

    private var blockMatchesSearch: Bool {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return false }
        return MarkdownDiffLogic.blockText(block).range(
            of: query,
            options: [.caseInsensitive, .diacriticInsensitive]
        ) != nil
    }

    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: return .system(size: 28, weight: .bold)
        case 2: return .system(size: 22, weight: .bold)
        case 3: return .system(size: 18, weight: .semibold)
        case 4: return .system(size: 16, weight: .semibold)
        case 5: return .system(size: 14, weight: .semibold)
        default: return .system(size: 13, weight: .semibold)
        }
    }
}

private struct MarkdownInlineText: View {
    let runs: [MarkdownInlineRun]
    let sourceURL: URL

    var body: some View {
        runs.reduce(Text("")) { partial, run in
            partial + styledText(for: run)
        }
    }

    private func styledText(for run: MarkdownInlineRun) -> Text {
        var attributed = AttributedString(run.text)
        if let destination = run.destination,
            let url = resolvedDestination(destination, relativeTo: sourceURL)
        {
            attributed.link = url
        }
        if run.styles.contains(.highlight) {
            attributed.backgroundColor = Color.yellow.opacity(0.35)
        }
        var text = Text(attributed)
        if run.styles.contains(.strong) { text = text.bold() }
        if run.styles.contains(.emphasis) { text = text.italic() }
        if run.styles.contains(.code) {
            text = text.font(.system(size: 13, design: .monospaced)).foregroundColor(.secondary)
        }
        if run.styles.contains(.strikethrough) { text = text.strikethrough() }
        return text
    }
}

private struct MarkdownListView: View {
    let items: [MarkdownListItemModel]
    let start: Int?
    let sourceURL: URL
    let searchQuery: String
    let highlightedBlockIDs: Set<Int>
    let onToggleTask: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            ForEach(items.indices, id: \.self) { index in
                HStack(alignment: .top, spacing: 9) {
                    marker(for: items[index], index: index)
                        .frame(width: 22, alignment: .trailing)
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(items[index].blocks) { block in
                            MarkdownBlockView(
                                block: block,
                                sourceURL: sourceURL,
                                searchQuery: searchQuery,
                                highlightedBlockIDs: highlightedBlockIDs,
                                onToggleTask: onToggleTask
                            )
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(.leading, 4)
    }

    @ViewBuilder
    private func marker(for item: MarkdownListItemModel, index: Int) -> some View {
        if let checked = item.checkbox {
            Button {
                if let ordinal = item.taskOrdinal {
                    onToggleTask(ordinal)
                }
            } label: {
                Image(systemName: checked ? "checkmark.square.fill" : "square")
                    .foregroundStyle(checked ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.plain)
            .disabled(item.taskOrdinal == nil)
        } else if let start {
            Text("\(start + index).")
                .font(.system(size: 14, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
        } else {
            Text("•")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(.secondary)
        }
    }
}

private struct MarkdownTableView: View {
    let table: MarkdownTableModel
    let sourceURL: URL

    var body: some View {
        ScrollView(.horizontal) {
            VStack(alignment: .leading, spacing: 0) {
                tableRow(table.header, isHeader: true)
                ForEach(table.rows.indices, id: \.self) { index in
                    tableRow(table.rows[index], isHeader: false)
                        .background(index.isMultiple(of: 2) ? Color.clear : Color.secondary.opacity(0.045))
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 5)
                    .stroke(Color.secondary.opacity(0.24), lineWidth: 1)
            }
        }
    }

    private func tableRow(_ cells: [[MarkdownInlineRun]], isHeader: Bool) -> some View {
        HStack(spacing: 0) {
            ForEach(cells.indices, id: \.self) { index in
                MarkdownInlineText(runs: cells[index], sourceURL: sourceURL)
                    .font(.system(size: 13, weight: isHeader ? .semibold : .regular))
                    .frame(width: 180, alignment: alignment(at: index))
                    .frame(minHeight: 34, alignment: alignment(at: index))
                    .padding(.horizontal, 9)
                    .overlay(alignment: .trailing) {
                        if index < cells.count - 1 {
                            Rectangle()
                                .fill(Color(nsColor: .separatorColor))
                                .frame(width: 1)
                                .frame(maxHeight: .infinity)
                        }
                    }
            }
        }
        .background(isHeader ? Color(nsColor: .controlBackgroundColor) : Color.clear)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color(nsColor: .separatorColor))
                .frame(height: 1)
        }
    }

    private func alignment(at index: Int) -> Alignment {
        guard table.alignments.indices.contains(index) else { return .leading }
        switch table.alignments[index] {
        case .leading: return .leading
        case .center: return .center
        case .trailing: return .trailing
        }
    }
}

private struct MarkdownLocalImageView: View {
    enum LoadState {
        case idle
        case loaded(CGImage)
        case unavailable
    }

    @EnvironmentObject private var store: WorkspaceStore
    let model: MarkdownImageModel
    let sourceURL: URL
    @State private var state = LoadState.idle

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch state {
            case .idle:
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 80)
            case .loaded(let image):
                Image(decorative: image, scale: 1)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 860, maxHeight: 520)
            case .unavailable:
                Label(
                    model.altText.isEmpty ? store.loc("图片不可用", "Image unavailable") : model.altText,
                    systemImage: "photo"
                )
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 72, alignment: .leading)
            }
            if let title = model.title, !title.isEmpty {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .task(id: model.source) {
            guard let url = localImageURL else {
                state = .unavailable
                return
            }
            state = await MarkdownImageLoader.thumbnail(from: url).map(LoadState.loaded) ?? .unavailable
        }
    }

    private var localImageURL: URL? {
        let decoded = model.source.removingPercentEncoding ?? model.source
        if let absolute = URL(string: decoded), let scheme = absolute.scheme {
            return scheme == "file" ? absolute : nil
        }
        if decoded.hasPrefix("/") { return URL(fileURLWithPath: decoded) }
        return sourceURL.deletingLastPathComponent().appendingPathComponent(decoded).standardizedFileURL
    }
}

private enum MarkdownImageLoader {
    static func thumbnail(from url: URL) async -> CGImage? {
        await Task.detached(priority: .utility) {
            guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                size <= 20 * 1_024 * 1_024,
                let source = CGImageSourceCreateWithURL(url as CFURL, nil)
            else { return nil }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 1_600,
                kCGImageSourceShouldCacheImmediately: false,
            ]
            return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        }.value
    }
}

private func resolvedDestination(_ destination: String, relativeTo sourceURL: URL) -> URL? {
    if destination.hasPrefix("#") { return nil }
    if let absolute = URL(string: destination), absolute.scheme != nil { return absolute }
    let decoded = destination.removingPercentEncoding ?? destination
    return sourceURL.deletingLastPathComponent().appendingPathComponent(decoded).standardizedFileURL
}
