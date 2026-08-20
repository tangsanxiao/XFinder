import SwiftUI

struct SidebarView: View {
    @EnvironmentObject private var store: WorkspaceStore
    @Binding var focusedDirectoryID: UUID?
    @State private var workspaceToRename: Workspace?
    @State private var renameDraft = ""
    @State private var starsExpanded = true
    @State private var bookmarksExpanded = false

    var body: some View {
        VStack(spacing: 0) {
            Color.clear
                .frame(height: 50)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(spacing: 2) {
                        agentCenterEntry
                        skillHubEntry
                    }
                    workspaceSection
                    starsSection
                    bookmarksSection
                }
                .padding(.top, 8)
                .padding(.bottom, 16)
            }

            Divider()
            sidebarFooter
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .alert("Rename Workspace", isPresented: renameAlertBinding) {
            TextField("Workspace name", text: $renameDraft)
            Button("Cancel", role: .cancel) {
                workspaceToRename = nil
            }
            Button("Rename") {
                if let workspaceToRename {
                    store.renameWorkspace(
                        id: workspaceToRename.id, to: renameDraft.trimmingCharacters(in: .whitespacesAndNewlines))
                }
                workspaceToRename = nil
            }
        }
    }

    /// Settings entry at the sidebar's bottom-left (Claude-desktop style); the
    /// standard ⌘, command is the other entry point.
    private var sidebarFooter: some View {
        HStack {
            Button {
                store.isSettingsPresented = true
            } label: {
                Image(systemName: "gearshape")
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .helpTip(store.loc("设置", "Settings"))
            Spacer()
        }
        .padding(.horizontal, 12)
        .frame(height: 36)
    }

    /// One entry for project-level review and the transcript catalog. The
    /// selected Agent Center section is retained in settings.
    private var agentCenterEntry: some View {
        let active = store.activePanel == .agent
        return HStack(spacing: 8) {
            Image(systemName: "tray.full")
                .font(.system(size: 12))
                .frame(width: 16)
                .foregroundStyle(active ? .blue : .secondary)
            Text("Agent Center")
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .frame(height: 30)
        .background(Rectangle().fill(active ? Color.accentColor.opacity(0.18) : Color.clear))
        .contentShape(Rectangle())
        .onTapGesture { store.activePanel = .agent }
    }

    private var skillHubEntry: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles")
                .font(.system(size: 12))
                .frame(width: 16)
                .foregroundStyle(store.showsSkillHub ? .blue : .secondary)
            Text(store.loc("Skill Center", "Skill Center"))
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .frame(height: 30)
        .background(
            Rectangle().fill(store.showsSkillHub ? Color.accentColor.opacity(0.18) : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture { store.activePanel = .skills }
    }

    private var workspaceSection: some View {
        VStack(spacing: 6) {
            HStack {
                Text("Workspaces")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    store.createWorkspace()
                    focusedDirectoryID = store.selectedWorkspace?.directories.first?.id
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("New workspace")
            }
            .padding(.horizontal, 14)

            ForEach(store.workspaces) { workspace in
                WorkspaceSidebarRow(
                    workspace: workspace,
                    // No workspace looks selected while the Skill Center is open.
                    isSelected: store.activePanel == .files && workspace.id == store.selectedWorkspaceID,
                    select: {
                        store.showsSkillHub = false
                        store.selectedWorkspaceID = workspace.id
                        focusedDirectoryID = workspace.directories.first?.id
                    },
                    rename: {
                        workspaceToRename = workspace
                        renameDraft = workspace.name
                    },
                    delete: {
                        store.deleteWorkspace(id: workspace.id)
                        focusedDirectoryID = store.selectedWorkspace?.directories.first?.id
                    }
                )
            }
        }
    }

    private var starsSection: some View {
        VStack(spacing: 6) {
            CollapsibleSectionHeader(title: "Stars", isExpanded: $starsExpanded)

            if starsExpanded {
                if store.stars.isEmpty {
                    Text("Star a folder from its pane toolbar")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 14)
                } else {
                    ForEach(store.stars) { star in
                        StarSidebarRow(
                            star: star,
                            open: { openDirectory(URL(fileURLWithPath: star.path), title: star.name) },
                            delete: { store.removeStar(star) }
                        )
                    }
                }
            }
        }
    }

    private var bookmarksSection: some View {
        VStack(spacing: 6) {
            CollapsibleSectionHeader(title: "Bookmarks", isExpanded: $bookmarksExpanded)

            if bookmarksExpanded {
                ForEach(store.systemBookmarks) { bookmark in
                    Button {
                        openDirectory(bookmark.url, title: bookmark.title)
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: bookmark.systemImage)
                                .font(.system(size: 12))
                                .frame(width: 16)
                                .foregroundStyle(.blue)
                            Text(bookmark.title)
                                .lineLimit(1)
                            Spacer()
                        }
                        .padding(.horizontal, 14)
                        .frame(height: 30)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    /// Opens a sidebar directory: fills a selected "待添加" placeholder with a new
    /// pane, otherwise retargets the focused pane.
    private func openDirectory(_ url: URL, title: String) {
        store.showsSkillHub = false
        if focusedDirectoryID == nil {
            // No pane focused — a "待添加" placeholder is the target. Add a new
            // pane and focus it (never retarget the first pane).
            focusedDirectoryID = store.openInNewPane(url, title: title)
        } else {
            focusedDirectoryID = store.openLocation(url: url, title: title, in: focusedDirectoryID)
        }
    }

    private var renameAlertBinding: Binding<Bool> {
        Binding(
            get: { workspaceToRename != nil },
            set: { if !$0 { workspaceToRename = nil } }
        )
    }
}

private struct CollapsibleSectionHeader: View {
    let title: String
    @Binding var isExpanded: Bool

    var body: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) { isExpanded.toggle() }
        } label: {
            HStack {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(.secondary)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
            }
            .padding(.horizontal, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct StarSidebarRow: View {
    let star: StarItem
    let open: () -> Void
    let delete: () -> Void
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "star")
                .font(.system(size: 12))
                .frame(width: 16)
                .foregroundStyle(.blue)
            Text(star.name)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            if isHovering {
                Button(action: delete) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Remove from Stars")
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 30)
        .contentShape(Rectangle())
        .onTapGesture(perform: open)
        .onHover { isHovering = $0 }
        .help(star.path)
        .contextMenu {
            Button("Remove from Stars", role: .destructive, action: delete)
        }
    }
}

struct WorkspaceSidebarRow: View {
    let workspace: Workspace
    let isSelected: Bool
    let select: () -> Void
    let rename: () -> Void
    let delete: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "square.stack")
                .font(.system(size: 12))
                .frame(width: 16)
                .foregroundStyle(isSelected ? .blue : .secondary)

            Text(workspace.name)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .frame(height: 30)
        .background(
            Rectangle()
                .fill(isSelected ? Color.accentColor.opacity(0.18) : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            select()
        }
        .contextMenu {
            Button("Rename") {
                rename()
            }
            Button("Delete", role: .destructive) {
                delete()
            }
        }
    }
}
