import SwiftUI

/// Unified view over chat sessions from every code agent (Claude, Codex).
/// Left: a filterable list (project, date, ~tokens). Right: the transcript and
/// summaries (instant deterministic, or via the configured third-party LLM).
struct SessionCenterView: View {
    @EnvironmentObject private var store: WorkspaceStore
    let isSidebarVisible: Bool

    @State private var sessions: [SessionSummary] = []
    @State private var isLoading = true
    @State private var selectedID: SessionSummary.ID?
    @State private var agentFilter: SessionAgent?
    @State private var query = ""
    @State private var transcriptIndex: [String: String] = [:]
    @State private var transcriptIndexing = false

    @State private var transcript: SessionTranscript?
    @State private var transcriptLoading = false
    @State private var transcriptTask: Task<Void, Never>?
    @State private var summaryText: String?
    @State private var summaryRunning = false
    @State private var summaryError: String?
    @State private var summaryTask: Task<Void, Never>?

    private var chinese: Bool { store.settings.language.isChineseResolved }
    private func loc(_ zh: String, _ en: String) -> String { store.loc(zh, en) }

    private var selected: SessionSummary? { sessions.first { $0.id == selectedID } }

    private var presentAgents: [SessionAgent] {
        SessionAgent.allCases.filter { agent in sessions.contains { $0.agent == agent } }
    }

    private var filtered: [SessionSummary] {
        sessions.filter { session in
            if let agentFilter, session.agent != agentFilter { return false }
            let q = query.trimmingCharacters(in: .whitespaces)
            if !q.isEmpty {
                return session.title.localizedCaseInsensitiveContains(q)
                    || session.project.localizedCaseInsensitiveContains(q)
                    || transcriptIndex[session.id]?.localizedCaseInsensitiveContains(q) == true
            }
            return true
        }
    }

    private var totalTokens: Int { sessions.reduce(0) { $0 + $1.approxTokens } }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if !isLoading, !sessions.isEmpty {
                filterBar
                Divider()
            }
            content
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .task { await reload(force: false) }
        .onChange(of: store.sessionCenterRequestedSessionID) { requestedID in
            guard let requestedID, let session = sessions.first(where: { $0.id == requestedID }) else { return }
            select(session)
            store.sessionCenterRequestedSessionID = nil
        }
        .onDisappear {
            transcriptTask?.cancel()
            summaryTask?.cancel()
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("Agent Center")
                .font(.system(size: 15, weight: .semibold))
            AgentCenterSectionPicker()
            if !isLoading {
                Text(
                    loc(
                        "\(sessions.count) 个会话 · ≈\(formatted(totalTokens)) tokens",
                        "\(sessions.count) sessions · ≈\(formatted(totalTokens)) tokens")
                )
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                Task { await reload(force: true) }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.plain)
            .help(loc("重新扫描", "Rescan"))
        }
        .padding(.leading, isSidebarVisible ? 14 : 112)
        .padding(.trailing, 14)
        .frame(height: 44)
    }

    private var filterBar: some View {
        HStack(spacing: 8) {
            chip(loc("全部", "All"), active: agentFilter == nil) { agentFilter = nil }
            ForEach(presentAgents) { agent in
                chip(agent.displayName, active: agentFilter == agent) {
                    agentFilter = agentFilter == agent ? nil : agent
                }
            }
            Spacer()
            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(.secondary)
                TextField(loc("搜索标题/项目", "Search title / project"), text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .frame(width: 180)
            }
            if transcriptIndexing {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, isSidebarVisible ? 14 : 18)
        .padding(.vertical, 6)
        .onChange(of: query) { newValue in
            guard !newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            Task { await buildTranscriptIndexIfNeeded() }
        }
    }

    @ViewBuilder
    private var content: some View {
        if isLoading {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if sessions.isEmpty {
            EmptyStateView(
                title: loc("未发现会话", "No sessions found"),
                systemImage: "bubble.left.and.bubble.right",
                description: loc("未在已知 agent 的会话目录中找到记录。", "No transcripts in the known agent session directories."))
        } else {
            HStack(spacing: 0) {
                list.frame(width: 320)
                Divider()
                detail.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    /// Sessions grouped by project folder, groups ordered by their most-recent
    /// session (so the project you touched last is on top).
    private var groupedByProject: [(project: String, sessions: [SessionSummary])] {
        var groups: [String: [SessionSummary]] = [:]
        var order: [String] = []
        for session in filtered {
            if groups[session.project] == nil { order.append(session.project) }
            groups[session.project, default: []].append(session)
        }
        return order.map { (project: $0, sessions: groups[$0]!) }
    }

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                ForEach(groupedByProject, id: \.project) { group in
                    Section {
                        ForEach(group.sessions) { session in
                            SessionRow(session: session, isSelected: session.id == selectedID, chinese: chinese)
                                .contentShape(Rectangle())
                                .onTapGesture { select(session) }
                        }
                    } header: {
                        HStack(spacing: 6) {
                            Image(systemName: "folder").font(.system(size: 10)).foregroundStyle(.secondary)
                            Text(group.project).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                            Text("\(group.sessions.count)").font(.system(size: 10)).foregroundStyle(.tertiary)
                            Spacer()
                        }
                        .padding(.horizontal, 14).padding(.vertical, 5)
                        .background(.ultraThinMaterial)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let selected {
            SessionDetailView(
                session: selected,
                transcript: transcript,
                transcriptLoading: transcriptLoading,
                summaryText: summaryText,
                summaryRunning: summaryRunning,
                summaryError: summaryError,
                llmConfigured: store.settings.summaryLLM.isUsable,
                chinese: chinese,
                onQuickSummary: { quickSummary() },
                onLLMSummary: { llmSummary() },
                onReveal: { NSWorkspace.shared.activateFileViewerSelecting([selected.url]) },
                onOpenProject: { openProject(for: selected) }
            )
        } else {
            EmptyStateView(
                title: loc("选择一个会话", "Select a session"),
                systemImage: "hand.point.left",
                description: loc("点击左侧任意会话查看历史与摘要。", "Click a session to view its history and summary."))
        }
    }

    private func chip(_ title: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .padding(.horizontal, 9).padding(.vertical, 3)
                .background(Capsule().fill(active ? Color.accentColor : Color.secondary.opacity(0.12)))
                .foregroundStyle(active ? Color.white : Color.secondary)
        }
        .buttonStyle(.plain)
    }

    private func select(_ session: SessionSummary) {
        transcriptTask?.cancel()
        selectedID = session.id
        transcript = nil
        summaryText = nil
        summaryError = nil
        summaryTask?.cancel()
        transcriptLoading = true
        transcriptTask = Task {
            let loaded = await SessionScanner.transcript(for: session.url)
            guard !Task.isCancelled, selectedID == session.id else { return }
            transcript = loaded
            transcriptLoading = false
        }
    }

    private func openProject(for session: SessionSummary) {
        guard let projectPath = session.projectPath else { return }
        store.agentInboxRequestedProjectID = URL(fileURLWithPath: projectPath).standardizedFileURL.path
        store.settings.agentCenterSection = .inbox
        store.activePanel = .agent
    }

    /// Instant, deterministic recap from the transcript — no LLM.
    private func quickSummary() {
        guard let transcript else { return }
        let users = transcript.messages.filter { $0.role == .user }
        let first = users.first?.text ?? ""
        let last = users.count > 1 ? users.last?.text ?? "" : ""
        var parts = [
            loc(
                "共 \(transcript.messages.count) 条消息,≈\(formatted(transcript.exactTokens)) tokens。",
                "\(transcript.messages.count) messages, ≈\(formatted(transcript.exactTokens)) tokens.")
        ]
        if !first.isEmpty { parts.append(loc("开始:", "Start: ") + oneLine(first)) }
        if !last.isEmpty { parts.append(loc("最后:", "Last: ") + oneLine(last)) }
        summaryError = nil
        summaryText = parts.joined(separator: "\n\n")
    }

    private func llmSummary() {
        guard let transcript else { return }
        summaryError = nil
        summaryRunning = true
        summaryText = nil
        // Cap the payload so a huge transcript doesn't blow the context/cost.
        let joined = transcript.messages.map { "\($0.role.rawValue): \($0.text)" }.joined(separator: "\n")
        let capped = String(joined.prefix(16000))
        let config = store.settings.summaryLLM
        summaryTask = Task {
            do {
                let result = try await SummaryLLMClient.summarize(text: capped, config: config)
                summaryText = result
            } catch is CancellationError {
            } catch {
                summaryError = error.localizedDescription
            }
            summaryRunning = false
        }
    }

    private func oneLine(_ text: String) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        return flat.count > 100 ? String(flat.prefix(100)) + "…" : flat
    }

    private func formatted(_ n: Int) -> String {
        if n >= 1000 { return String(format: "%.0fk", Double(n) / 1000) }
        return "\(n)"
    }

    private func reload(force: Bool) async {
        isLoading = true
        sessions = await store.sessionCatalog.sessions(force: force)
        transcriptIndex = [:]
        if let requestedID = store.sessionCenterRequestedSessionID,
            let requested = sessions.first(where: { $0.id == requestedID })
        {
            selectedID = requestedID
            isLoading = false
            select(requested)
            store.sessionCenterRequestedSessionID = nil
            return
        }
        if selectedID == nil || !sessions.contains(where: { $0.id == selectedID }) {
            selectedID = nil
        }
        isLoading = false
    }

    private func buildTranscriptIndexIfNeeded() async {
        guard !transcriptIndexing, transcriptIndex.count < sessions.count else { return }
        transcriptIndexing = true
        var next = transcriptIndex
        for session in sessions where next[session.id] == nil {
            let transcript = await SessionScanner.transcript(for: session.url)
            next[session.id] = transcript.messages.map(\.text).joined(separator: "\n")
        }
        transcriptIndex = next
        transcriptIndexing = false
    }
}

private struct SessionRow: View {
    let session: SessionSummary
    let isSelected: Bool
    let chinese: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(session.title)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(2)
            HStack(spacing: 6) {
                Text(session.agent.displayName)
                    .font(.system(size: 9, weight: .medium))
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Capsule().fill(Color.secondary.opacity(0.15)))
                    .foregroundStyle(.secondary)
                Text(Self.dateFormatter.string(from: session.modified))
                    .font(.system(size: 9)).foregroundStyle(.tertiary)
                Spacer(minLength: 4)
                Text("≈\(session.approxTokens / 1000)k").font(.system(size: 9)).foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isSelected ? Color.accentColor.opacity(0.16) : Color.clear)
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()
}

private enum SessionDetailDisplayMode: String {
    case text
    case markdown
}

private struct SessionDetailView: View {
    @EnvironmentObject private var store: WorkspaceStore
    let session: SessionSummary
    let transcript: SessionTranscript?
    let transcriptLoading: Bool
    let summaryText: String?
    let summaryRunning: Bool
    let summaryError: String?
    let llmConfigured: Bool
    let chinese: Bool
    let onQuickSummary: () -> Void
    let onLLMSummary: () -> Void
    let onReveal: () -> Void
    let onOpenProject: () -> Void

    @State private var displayMode = SessionDetailDisplayMode.text
    @State private var markdownTranscript: SessionMarkdownTranscript?
    @State private var markdownSessionID: SessionSummary.ID?
    @State private var markdownLoading = false
    @State private var copyMarkdownTask: Task<Void, Never>?

    private func loc(_ zh: String, _ en: String) -> String { chinese ? zh : en }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 10) {
                    Text(session.title)
                        .font(.system(size: 16, weight: .semibold))
                        .lineLimit(2)
                        .textSelection(.enabled)
                    Spacer(minLength: 8)
                    Picker("", selection: $displayMode) {
                        Text(loc("文本", "Text")).tag(SessionDetailDisplayMode.text)
                        Text("Markdown").tag(SessionDetailDisplayMode.markdown)
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 146)
                    if displayMode == .markdown, transcript != nil {
                        Button {
                            copyMarkdown()
                        } label: {
                            Image(systemName: "doc.on.doc")
                        }
                        .buttonStyle(.plain)
                        .help(loc("复制 Markdown", "Copy Markdown"))
                    }
                }
                HStack(spacing: 10) {
                    Label(session.agent.displayName, systemImage: "cpu").font(.system(size: 11)).foregroundStyle(
                        .secondary)
                    Label(session.project, systemImage: "folder").font(.system(size: 11)).foregroundStyle(.secondary)
                    Button {
                        onReveal()
                    } label: {
                        Image(systemName: "arrow.up.forward.app")
                    }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .help(loc("在 Finder 中显示", "Reveal in Finder"))
                    if session.projectPath != nil {
                        Button {
                            onOpenProject()
                        } label: {
                            Label(loc("返回项目", "Back to project"), systemImage: "arrowshape.turn.up.backward")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help(loc("在 Agent Inbox 中打开项目", "Open project in Agent Inbox"))
                    }
                }
                summaryBar
            }
            .padding(16)
            Divider()
            transcriptView
        }
        .task(id: markdownTaskID) { await loadMarkdownIfNeeded() }
        .onChange(of: session.id) { _ in
            markdownTranscript = nil
            markdownSessionID = nil
        }
        .onDisappear { copyMarkdownTask?.cancel() }
    }

    private var summaryBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Button {
                    onQuickSummary()
                } label: {
                    Label(loc("快速摘要", "Quick summary"), systemImage: "text.alignleft")
                }
                .controlSize(.small).disabled(transcript == nil)
                Button {
                    onLLMSummary()
                } label: {
                    Label(loc("用 LLM 总结", "Summarize with LLM"), systemImage: "sparkles")
                }
                .controlSize(.small).disabled(transcript == nil || !llmConfigured || summaryRunning)
                if !llmConfigured {
                    Text(loc("（在设置中配置 LLM 后可用）", "(configure an LLM in Settings)"))
                        .font(.caption).foregroundStyle(.tertiary)
                }
                if summaryRunning { ProgressView().controlSize(.small) }
            }
            .buttonStyle(.bordered)

            if let summaryError {
                Text(summaryError).font(.caption).foregroundStyle(.red).textSelection(.enabled)
            } else if let summaryText {
                ScrollView {
                    Text(summaryText).font(.system(size: 12)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 140)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
            }
        }
    }

    @ViewBuilder
    private var transcriptView: some View {
        if transcriptLoading {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let transcript {
            switch displayMode {
            case .text:
                plainTranscriptView(transcript)
            case .markdown:
                markdownTranscriptView(transcript)
            }
        } else {
            Color.clear
        }
    }

    private func plainTranscriptView(_ transcript: SessionTranscript) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                if transcript.wasTruncated { truncationNotice }
                ForEach(transcript.messages) { message in
                    messageContainer(role: message.role) {
                        Text(message.text)
                            .font(.system(size: 12))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding(16)
        }
    }

    @ViewBuilder
    private func markdownTranscriptView(_ transcript: SessionTranscript) -> some View {
        if markdownLoading || markdownSessionID != session.id || markdownTranscript == nil {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let markdownTranscript {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if markdownTranscript.wasTruncated { truncationNotice }
                    ForEach(markdownTranscript.turns) { turn in
                        conversationTurnContainer(role: turn.role) {
                            VStack(alignment: .leading, spacing: 8) {
                                ForEach(turn.document.blocks) { block in
                                    MarkdownBlockView(
                                        block: block,
                                        sourceURL: markdownSourceURL,
                                        searchQuery: "",
                                        highlightedBlockIDs: [],
                                        onToggleTask: { _ in }
                                    )
                                }
                                if turn.document.blocks.isEmpty {
                                    Text(loc("空消息", "Empty message"))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .padding(16)
            }
        }
    }

    private func messageContainer<Content: View>(
        role: SessionMessage.Role,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(role == .user ? loc("用户", "User") : "Assistant")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(role == .user ? Color.accentColor : Color.secondary)
            content()
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(role == .user ? Color.accentColor.opacity(0.06) : Color.secondary.opacity(0.06))
        )
    }

    private func conversationTurnContainer<Content: View>(
        role: SessionMessage.Role,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(alignment: .top, spacing: 0) {
            if role == .user { Spacer(minLength: 56) }
            VStack(alignment: .leading, spacing: 6) {
                Text(role == .user ? loc("用户", "User") : "Assistant")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(role == .user ? Color.accentColor : Color.secondary)
                    .frame(maxWidth: .infinity, alignment: role == .user ? .trailing : .leading)
                content()
            }
            .padding(12)
            .frame(maxWidth: role == .user ? 680 : .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(role == .user ? Color.accentColor.opacity(0.11) : Color.secondary.opacity(0.06))
            )
            if role == .assistant { Spacer(minLength: 56) }
        }
        .frame(maxWidth: .infinity, alignment: role == .user ? .trailing : .leading)
    }

    private var truncationNotice: some View {
        Label(
            loc("为保证性能，会话内容已按上限抽样", "Session content sampled to stay within performance limits"),
            systemImage: "gauge.with.dots.needle.33percent"
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(Color.secondary.opacity(0.07))
    }

    private var markdownTaskID: String {
        "\(session.id):\(displayMode.rawValue):\(transcript?.messages.count ?? -1):\(transcript?.exactTokens ?? -1)"
    }

    private var markdownSourceURL: URL {
        guard let projectPath = session.projectPath else { return session.url }
        return URL(fileURLWithPath: projectPath, isDirectory: true).appendingPathComponent("session.md")
    }

    private func loadMarkdownIfNeeded() async {
        guard displayMode == .markdown, let transcript else { return }
        if markdownSessionID == session.id, markdownTranscript != nil { return }
        markdownLoading = true
        let rendered = await SessionMarkdownRendering.render(transcript)
        guard !Task.isCancelled, displayMode == .markdown else { return }
        markdownTranscript = rendered
        markdownSessionID = session.id
        markdownLoading = false
    }

    private func copyMarkdown() {
        guard let transcript else { return }
        copyMarkdownTask?.cancel()
        copyMarkdownTask = Task {
            guard let source = await SessionMarkdownRendering.sourceAsync(from: transcript), !Task.isCancelled else {
                return
            }
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            guard pasteboard.setString(source, forType: .string) else {
                store.lastError = loc("复制 Markdown 失败", "Could not copy Markdown")
                return
            }
            store.statusMessage = loc("已复制会话 Markdown", "Copied session Markdown")
        }
    }
}
