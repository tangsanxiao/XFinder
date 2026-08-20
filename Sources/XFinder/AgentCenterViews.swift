import SwiftUI

struct AgentCenterSectionPicker: View {
    @EnvironmentObject private var store: WorkspaceStore

    var body: some View {
        Picker("", selection: $store.settings.agentCenterSection) {
            Text(store.loc("Inbox", "Inbox")).tag(AgentCenterSection.inbox)
            Text(store.loc("会话", "Sessions")).tag(AgentCenterSection.sessions)
        }
        .labelsHidden()
        .pickerStyle(.segmented)
        .frame(width: 156)
        .accessibilityLabel(store.loc("Agent Center 视图", "Agent Center view"))
    }
}
