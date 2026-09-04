import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var store: WorkspaceStore
    @StateObject private var tooltip = TooltipCenter()
    @StateObject private var networkDiagnostics = NetworkDiagnosticsController()
    @State private var paneViewModes: [UUID: BrowserViewMode] = [:]
    @State private var isSidebarVisible = true

    /// Focus is owned by the store (single source of truth); this binding lets
    /// the existing child views keep their `focusedDirectoryID` interface.
    private var focusedDirectoryID: Binding<UUID?> {
        Binding(get: { store.focusedPaneID }, set: { store.focusedPaneID = $0 })
    }

    var body: some View {
        HStack(spacing: 0) {
            if isSidebarVisible {
                SidebarView(
                    focusedDirectoryID: focusedDirectoryID
                )
                .frame(width: 175)

                Divider()
            }

            switch store.activePanel {
            case .skills:
                SkillHubView(isSidebarVisible: isSidebarVisible)
            case .agent:
                switch store.settings.agentCenterSection {
                case .inbox:
                    AgentInboxView(isSidebarVisible: isSidebarVisible)
                case .sessions:
                    SessionCenterView(isSidebarVisible: isSidebarVisible)
                }
            case .network:
                NetworkStatusView(controller: networkDiagnostics, isSidebarVisible: isSidebarVisible)
            case .files:
                WorkspaceDetailView(
                    focusedDirectoryID: focusedDirectoryID,
                    paneViewModes: $paneViewModes,
                    isSidebarVisible: $isSidebarVisible
                )
            }
        }
        // Sidebar toggle pinned at the top-left next to the traffic lights
        // (Claude-desktop style): it stays put while the sidebar slides.
        .overlay(alignment: .topLeading) {
            // Center the toggle in a band the height of the standard title bar
            // (28pt), where macOS vertically centers the traffic lights — so
            // their centers line up without pixel-guessing a top offset.
            SidebarToggleButton(isOn: $isSidebarVisible)
                .frame(height: 28)
                .padding(.leading, 76)
        }
        // The window-level tooltip layer + shared coordinate space, so every
        // control's helpTip anchors and the bubble use the same origin and the
        // bubble can be clamped inside the window.
        .coordinateSpace(name: tooltipCoordinateSpace)
        .environmentObject(tooltip)
        .overlay { TooltipOverlay().environmentObject(tooltip) }
        .overlay(alignment: .bottomTrailing) {
            FileTaskOverlay()
        }
        .ignoresSafeArea(.container, edges: .top)
        .background(WindowChromeConfigurator())
        .sheet(isPresented: settingsBinding) {
            SettingsView(onClose: { store.isSettingsPresented = false })
        }
        .onAppear {
            if store.focusedPaneID == nil {
                store.focusedPaneID = store.selectedWorkspace?.directories.first?.id
            }
        }
        .onChange(of: store.selectedWorkspaceID) { _ in
            store.focusedPaneID = store.selectedWorkspace?.directories.first?.id
        }
        .alert("XFinder", isPresented: errorBinding) {
            Button("OK") {
                store.lastError = nil
            }
        } message: {
            Text(store.lastError ?? "")
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { store.lastError != nil },
            set: { if $0 == false { store.lastError = nil } }
        )
    }

    private var settingsBinding: Binding<Bool> {
        Binding(
            get: { store.isSettingsPresented },
            set: { store.isSettingsPresented = $0 }
        )
    }
}

/// The window's sidebar toggle, sized and styled to sit in the traffic-light
/// row at the top-left, like Claude desktop.
private struct SidebarToggleButton: View {
    @EnvironmentObject private var store: WorkspaceStore
    @Binding var isOn: Bool
    @State private var isHovering = false

    var body: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.18)) { isOn.toggle() }
        } label: {
            // Glyph reflects state (Claude-style): the left column is filled
            // when the sidebar is showing, hollow when it's collapsed. Sized to
            // the traffic-light dots so the row's heights line up.
            Image(systemName: isOn ? "sidebar.squares.left" : "sidebar.left")
                .font(.system(size: 13, weight: .regular))
                .frame(width: 20, height: 13)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(Color.secondary.opacity(isHovering ? 0.18 : 0))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(isOn ? Color.primary : Color.secondary)
        .onHover { isHovering = $0 }
        .helpTip(isOn ? store.loc("收起侧边栏", "Collapse sidebar") : store.loc("展开侧边栏", "Expand sidebar"))
    }
}
