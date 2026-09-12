import SwiftUI

struct FeatureOverviewSheet: View {
    static let repositoryURL = URL(string: "https://github.com/tangsanxiao/XFinder")!

    @EnvironmentObject private var store: WorkspaceStore
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label(store.loc("功能简介", "Feature Overview"), systemImage: "info.circle")
                    .font(.headline)
                Spacer()
                Button(store.loc("关闭", "Close"), action: onClose)
                    .keyboardShortcut(.cancelAction)
            }
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("XFinder").font(.title2.bold())
                    feature(
                        "多面板文件管理", "Multi-pane File Management", icon: "square.grid.2x2",
                        zh: "工作区、文件预览、搜索、排序、压缩和常用文件操作。",
                        en: "Workspaces, file previews, search, sorting, compression, and everyday file operations."
                    )
                    feature(
                        "Agent 中心", "Agent Center", icon: "tray.full",
                        zh: "查看 Claude 和 Codex 项目变更，以对话形式阅读会话，并管理技能库。",
                        en:
                            "Review Claude and Codex project changes, read sessions as conversations, and manage skills."
                    )
                    feature(
                        "Markdown 与朗读", "Markdown & Read Aloud", icon: "doc.text",
                        zh: "轻量 Markdown 阅读与编辑，支持文档朗读和可选豆包语音。",
                        en:
                            "Lightweight Markdown reading and editing, with document read-aloud and optional Doubao Speech."
                    )
                    feature(
                        "网络测试", "Network Diagnostics", icon: "network",
                        zh: "检测节点可达性、延迟与稳定性，查看出口信息，并按需测试网络带宽。",
                        en:
                            "Check endpoint reachability, latency, stability, and egress details, with on-demand bandwidth tests."
                    )
                    feature(
                        "Token 用量", "Token Usage", icon: "chart.bar",
                        zh: "离线统计本机各 AI 工具的 token 用量、缓存命中率与估算成本，并展示 Codex 配额。",
                        en:
                            "Offline token usage, cache hit rates, and estimated costs across local AI tools, plus Codex quota."
                    )
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
            }
            Divider()
            Link("github.com/tangsanxiao/XFinder", destination: Self.repositoryURL)
                .font(.callout)
        }
        .padding(20)
        .frame(width: 560, height: 470)
    }

    private func feature(_ zhTitle: String, _ enTitle: String, icon: String, zh: String, en: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(store.loc(zhTitle, enTitle), systemImage: icon)
                .font(.system(size: 13, weight: .semibold))
            Text(store.loc(zh, en))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
