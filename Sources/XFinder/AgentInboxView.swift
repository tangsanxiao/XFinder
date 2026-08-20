import SwiftUI

struct AgentInboxView: View {
    @EnvironmentObject private var store: WorkspaceStore
    let isSidebarVisible: Bool

    @State private var selectedID: AgentInboxProject.ID?
    @State private var selectedProjectIDs: Set<AgentInboxProject.ID> = []
    @State private var selectionAnchorID: AgentInboxProject.ID?
    @State private var query = ""
    @State private var showsDiff = false
    @State private var diffFileName = ""
    @State private var diffLoading = false
    @State private var diffLines: [DiffLine] = []
    @State private var diffTask: Task<Void, Never>?

    private var chinese: Bool { store.settings.language.isChineseResolved }
    private func loc(_ zh: String, _ en: String) -> String { store.loc(zh, en) }

    private var filtered: [AgentInboxProject] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let projects = store.agentInboxVisibleProjects
        guard !q.isEmpty else { return projects }
        return projects.filter { project in
            project.name.localizedCaseInsensitiveContains(q)
                || project.url.path.localizedCaseInsensitiveContains(q)
                || project.sessions.contains { $0.title.localizedCaseInsensitiveContains(q) }
        }
    }

    private var selected: AgentInboxProject? {
        filtered.first { $0.id == selectedID }
            ?? filtered.first { selectedProjectIDs.contains($0.id) }
            ?? filtered.first
    }

    private var selectedProjects: [AgentInboxProject] {
        filtered.filter { selectedProjectIDs.contains($0.id) }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if !store.agentInboxProjects.isEmpty {
                filterBar
                Divider()
            }
            content
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .task {
            await store.ensureAgentInboxLoaded()
            selectRequestedProject(store.agentInboxRequestedProjectID)
        }
        .onChange(of: store.agentInboxRequestedProjectID) { selectRequestedProject($0) }
        .task(id: extractionTaskID) {
            if let selected {
                await store.loadAgentInboxExtractedItems(for: selected)
            }
        }
        .sheet(isPresented: $showsDiff, onDismiss: { diffTask?.cancel() }) {
            DiffSheet(
                fileName: diffFileName,
                chinese: chinese,
                isLoading: diffLoading,
                lines: diffLines,
                claudeEnabled: false,
                onExplain: {},
                onClose: { showsDiff = false }
            )
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("Agent Center")
                .font(.system(size: 15, weight: .semibold))
            AgentCenterSectionPicker()
            if !store.agentInboxProjects.isEmpty {
                Text(loc("\(filtered.count) 个项目", "\(filtered.count) projects"))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if store.agentInboxIsRefreshing {
                ProgressView()
                    .controlSize(.small)
            }
            Button {
                Task { await store.refreshAgentInbox(force: true) }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.plain)
            .helpTip(loc("重新扫描", "Rescan"))
        }
        .padding(.leading, isSidebarVisible ? 14 : 112)
        .padding(.trailing, 14)
        .frame(height: 44)
    }

    private var filterBar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 5) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                TextField(loc("搜索项目/会话", "Search projects / sessions"), text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
            }
            Spacer()
            if !selectedProjects.isEmpty {
                Text(loc("\(selectedProjects.count) 已选", "\(selectedProjects.count) selected"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button {
                    hideSelectedProjects()
                } label: {
                    Label(loc("隐藏", "Hide"), systemImage: "eye.slash")
                }
                .controlSize(.small)
                .helpTip(loc("隐藏选中的项目", "Hide selected projects"))
            }
            if store.agentInboxHiddenCount > 0 {
                Button {
                    store.agentInboxShowsHidden.toggle()
                } label: {
                    Image(systemName: store.agentInboxShowsHidden ? "eye" : "eye.slash")
                }
                .buttonStyle(.plain)
                .helpTip(
                    store.agentInboxShowsHidden
                        ? loc("隐藏已忽略项目", "Hide ignored projects")
                        : loc("显示已忽略项目", "Show ignored projects"))
            }
            Text(statusText)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, isSidebarVisible ? 14 : 18)
        .padding(.vertical, 7)
    }

    private var statusText: String {
        if let date = store.agentInboxLastUpdated {
            return loc(
                "上次更新 \(Self.relativeFormatter.localizedString(for: date, relativeTo: Date()))",
                "Updated \(Self.relativeFormatter.localizedString(for: date, relativeTo: Date()))")
        }
        return loc("本地 Claude / Codex", "Local Claude / Codex")
    }

    private var extractionTaskID: String {
        "\(selected?.id ?? "none"):\(store.agentInboxLastUpdated?.timeIntervalSince1970 ?? 0)"
    }

    @ViewBuilder
    private var content: some View {
        if store.agentInboxIsRefreshing, store.agentInboxProjects.isEmpty {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if filtered.isEmpty {
            EmptyStateView(
                title: store.agentInboxProjects.isEmpty
                    ? loc("没有发现 agent 活动", "No agent activity found")
                    : loc("没有匹配的项目", "No matching projects"),
                systemImage: "tray",
                description: loc(
                    "可使用刷新重新扫描,或打开已忽略项目查看被隐藏的条目。",
                    "Refresh to rescan, or show ignored projects to review hidden entries."
                ))
        } else {
            HStack(spacing: 0) {
                projectList.frame(width: 340)
                Divider()
                if let selected {
                    AgentInboxDetail(
                        project: selected,
                        chinese: chinese,
                        claudeEnabled: store.settings.claudeIntegrationEnabled,
                        isExtractingItems: store.agentInboxExtractingProjectIDs.contains(selected.id),
                        onOpenProject: { openProject(selected.url) },
                        onOpenTerminal: { store.openTerminal(at: selected.url) },
                        onOpenClaudeCode: { store.openClaudeCode(at: selected.url) },
                        onCopyCommitMessage: { copyCommitMessage(selected.commitMessageDraft) },
                        onOpenSession: { openSession($0) },
                        onOpenChange: { openChange($0) },
                        onShowDiff: { showDiff(for: $0, project: selected) }
                    )
                } else {
                    EmptyStateView(
                        title: loc("选择一个项目", "Select a project"),
                        systemImage: "hand.point.left",
                        description: loc("点击左侧项目查看 review 摘要。", "Click a project to review its changes."))
                }
            }
        }
    }

    private var projectList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(filtered) { project in
                    AgentInboxProjectRow(
                        project: project,
                        isSelected: isProjectSelected(project),
                        isPinned: store.isAgentInboxProjectPinned(project),
                        isHidden: store.isAgentInboxProjectHidden(project),
                        chinese: chinese
                    )
                    .contentShape(Rectangle())
                    .onTapGesture { selectProject(project) }
                    .contextMenu {
                        Button {
                            store.toggleAgentInboxPin(project)
                        } label: {
                            Label(
                                store.isAgentInboxProjectPinned(project)
                                    ? loc("取消置顶", "Unpin")
                                    : loc("置顶", "Pin"),
                                systemImage: "pin")
                        }
                        Divider()
                        if selectedProjects.count > 1, selectedProjectIDs.contains(project.id) {
                            Button {
                                hideSelectedProjects()
                            } label: {
                                Label(
                                    loc("隐藏 \(selectedProjects.count) 个项目", "Hide \(selectedProjects.count) Projects"),
                                    systemImage: "eye.slash")
                            }
                            Divider()
                        }
                        Button {
                            if store.isAgentInboxProjectHidden(project) {
                                store.unhideAgentInboxProject(project)
                            } else {
                                store.hideAgentInboxProject(project)
                                if selectedID == project.id { selectedID = nil }
                            }
                        } label: {
                            Label(
                                store.isAgentInboxProjectHidden(project)
                                    ? loc("恢复到 Inbox", "Restore to Inbox")
                                    : loc("从 Inbox 隐藏", "Hide from Inbox"),
                                systemImage: store.isAgentInboxProjectHidden(project) ? "eye" : "eye.slash")
                        }
                    }
                }
            }
        }
    }

    private func openProject(_ url: URL) {
        store.activePanel = .files
        _ = store.openLocation(url: url, title: url.lastPathComponent, in: store.focusedPaneID)
    }

    private func isProjectSelected(_ project: AgentInboxProject) -> Bool {
        selectedProjectIDs.isEmpty ? project.id == selected?.id : selectedProjectIDs.contains(project.id)
    }

    private func selectProject(_ project: AgentInboxProject) {
        let modifiers = NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if modifiers.contains(.shift), let anchorID = selectionAnchorID {
            selectProjectRange(from: anchorID, to: project.id)
        } else if modifiers.contains(.command) {
            toggleProjectSelection(project)
        } else {
            selectedProjectIDs = [project.id]
            selectedID = project.id
            selectionAnchorID = project.id
        }
    }

    private func selectProjectRange(from anchorID: AgentInboxProject.ID, to targetID: AgentInboxProject.ID) {
        guard let anchorIndex = filtered.firstIndex(where: { $0.id == anchorID }),
            let targetIndex = filtered.firstIndex(where: { $0.id == targetID })
        else {
            selectedProjectIDs = [targetID]
            selectedID = targetID
            selectionAnchorID = targetID
            return
        }
        let bounds = min(anchorIndex, targetIndex)...max(anchorIndex, targetIndex)
        selectedProjectIDs = Set(filtered[bounds].map(\.id))
        selectedID = targetID
    }

    private func toggleProjectSelection(_ project: AgentInboxProject) {
        if selectedProjectIDs.isEmpty, let selectedID {
            selectedProjectIDs.insert(selectedID)
        }
        if selectedProjectIDs.contains(project.id) {
            selectedProjectIDs.remove(project.id)
        } else {
            selectedProjectIDs.insert(project.id)
            selectedID = project.id
        }
        if selectedProjectIDs.isEmpty {
            selectedID = nil
        } else if let selectedID, !selectedProjectIDs.contains(selectedID) {
            self.selectedID = filtered.first { selectedProjectIDs.contains($0.id) }?.id
        }
        selectionAnchorID = project.id
    }

    private func hideSelectedProjects() {
        let targets = selectedProjects
        guard !targets.isEmpty else { return }
        store.hideAgentInboxProjects(targets)
        selectedProjectIDs.removeAll()
        selectedID = nil
        selectionAnchorID = nil
    }

    private func openSession(_ session: SessionSummary) {
        store.sessionCenterRequestedSessionID = session.id
        store.settings.agentCenterSection = .sessions
        store.activePanel = .agent
    }

    private func selectRequestedProject(_ projectID: AgentInboxProject.ID?) {
        guard let projectID,
            let project = store.agentInboxProjects.first(where: { $0.id == projectID })
        else { return }
        if store.isAgentInboxProjectHidden(project) {
            store.agentInboxShowsHidden = true
        }
        selectedID = projectID
        selectedProjectIDs = [projectID]
        selectionAnchorID = projectID
        store.agentInboxRequestedProjectID = nil
    }

    private func openChange(_ change: RecentChange) {
        store.activePanel = .files
        let parent = change.url.deletingLastPathComponent()
        _ = store.openLocation(url: parent, title: parent.lastPathComponent, in: store.focusedPaneID)
    }

    private func showDiff(for change: RecentChange, project: AgentInboxProject) {
        guard let snapshot = project.gitSnapshot else { return }
        diffFileName = change.url.lastPathComponent
        diffLines = []
        diffLoading = true
        showsDiff = true
        diffTask?.cancel()
        diffTask = Task {
            let output = await GitStatusService.diff(
                for: change.url, repoRoot: snapshot.repoRoot, status: change.status)
            if Task.isCancelled { return }
            guard let output else {
                diffLines = []
                diffLoading = false
                store.lastError = loc(
                    "无法加载 diff: \(change.url.lastPathComponent)", "Failed to load diff: \(change.url.lastPathComponent)"
                )
                return
            }
            diffLines = GitStatusService.parseDiff(output)
            diffLoading = false
        }
    }

    private func copyCommitMessage(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        store.statusMessage = loc("已复制 commit message", "Copied commit message")
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()
}

private struct AgentInboxProjectRow: View {
    let project: AgentInboxProject
    let isSelected: Bool
    let isPinned: Bool
    let isHidden: Bool
    let chinese: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: project.riskLevel.systemImage)
                    .foregroundStyle(color(for: project.riskLevel))
                    .frame(width: 16)
                Text(project.name)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Spacer()
                if isPinned {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.blue)
                }
                if isHidden {
                    Image(systemName: "eye.slash")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                if project.changedCount > 0 {
                    Text("\(project.changedCount)")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.orange)
                }
            }
            Text(project.url.path)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            HStack(spacing: 8) {
                Label("\(project.sessions.count)", systemImage: "bubble.left.and.bubble.right")
                Label("\(project.recentChanges.count)", systemImage: "plusminus")
                Text(project.riskLevel.title)
                    .foregroundStyle(color(for: project.riskLevel))
                Spacer()
                Text(Self.dateFormatter.string(from: project.latestActivity))
            }
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
        }
        .opacity(isHidden ? 0.58 : 1)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isSelected ? Color.accentColor.opacity(0.16) : Color.clear)
    }

    private func color(for level: AgentRiskLevel) -> Color {
        switch level {
        case .low: .green
        case .medium: .orange
        case .high: .red
        }
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter
    }()

}
