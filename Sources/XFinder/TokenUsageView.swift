import SwiftUI

struct TokenUsageView: View {
    @EnvironmentObject private var store: WorkspaceStore
    @ObservedObject var controller: TokenUsageController
    let isSidebarVisible: Bool
    /// Session file path → display title, from the shared session catalog
    /// cache (no rescan); rows fall back to the file name when absent.
    @State private var sessionTitles: [String: String] = [:]

    private var files: [String: UsageFileContribution] { controller.ledger.files }
    private var today: String { UsageDayKey.make(for: Date()) }
    private var sevenDaysAgo: String { UsageDayKey.offset(-6) }
    private var thirtyDaysAgo: String { UsageDayKey.offset(-29) }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if controller.ledger.files.isEmpty, !controller.isScanning {
                        emptyState
                    } else {
                        overview
                        rateLimitSection
                        toolSection
                        trendSection
                        topSessionsSection
                    }
                    footer
                }
                .padding(16)
                .textSelection(.enabled)
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .onAppear {
            controller.activate(config: store.settings.tokenUsage)
        }
        .task {
            if let summaries = await store.sessionCatalog.cachedSessions() {
                sessionTitles = Dictionary(
                    uniqueKeysWithValues: summaries.map { ($0.url.standardizedFileURL.path, $0.title) })
            }
        }
        .onDisappear { controller.deactivate() }
        .onChange(of: store.settings.tokenUsage) { newConfig in
            controller.applyConfig(newConfig)
        }
        .onChange(of: controller.notice) { newNotice in
            guard let newNotice else { return }
            let message = store.loc(newNotice.zh, newNotice.en)
            if newNotice.isError {
                store.lastError = message
            } else {
                store.statusMessage = message
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            Label(store.loc("Token 用量", "Token Usage"), systemImage: "chart.xyaxis.line")
                .font(.system(size: 15, weight: .semibold))
            if controller.isScanning {
                ProgressView()
                    .controlSize(.small)
                if let progress = controller.progress, progress.filesTotal > 0 {
                    Text("\(progress.filesDone)/\(progress.filesTotal) · \(compactBytes(progress.bytesRead))")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            } else if let lastUpdated = controller.lastUpdated {
                Text(store.loc("更新于 ", "Updated ") + DisplayFormatters.date(lastUpdated))
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            Button {
                controller.refresh()
            } label: {
                Label(store.loc("刷新", "Refresh"), systemImage: "arrow.clockwise")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(controller.isScanning)
        }
        .padding(.leading, isSidebarVisible ? 14 : 112)
        .padding(.trailing, 14)
        .frame(height: 44)
    }

    // MARK: - Overview cards

    private var overview: some View {
        let todayTotals = UsageAggregation.totals(files: files, sinceDay: today)
        let weekTotals = UsageAggregation.totals(files: files, sinceDay: sevenDaysAgo)
        let monthTotals = UsageAggregation.totals(files: files, sinceDay: thirtyDaysAgo)
        let monthModels = UsageAggregation.totalsByModel(files: files, sinceDay: thirtyDaysAgo)
        let monthCost = UsageAggregation.costUSD(modelTotals: monthModels)
        return LazyVGrid(
            columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())],
            spacing: 12
        ) {
            UsageSummaryCard(title: store.loc("今日", "Today"), systemImage: "sun.max") {
                metric(todayTotals)
            }
            UsageSummaryCard(title: store.loc("近 7 日", "Last 7 Days"), systemImage: "calendar") {
                metric(weekTotals)
            }
            UsageSummaryCard(title: store.loc("近 30 日", "Last 30 Days"), systemImage: "calendar.badge.clock") {
                metric(monthTotals)
            }
            if store.settings.tokenUsage.showsCostEstimate {
                UsageSummaryCard(title: store.loc("近 30 日成本", "30-Day Cost"), systemImage: "dollarsign.circle") {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(String(format: "$%.2f", monthCost.value))
                            .font(.system(size: 16, weight: .semibold, design: .monospaced))
                        Text(
                            monthCost.complete
                                ? store.loc("按内置价目表估算", "Estimated from the built-in price list")
                                : store.loc("估算 · 部分模型无价目", "Estimated · some models unpriced")
                        )
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }

    private func metric(_ totals: UsageTotals) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(compactTokens(totals.total))
                .font(.system(size: 16, weight: .semibold, design: .monospaced))
            Text(
                store.loc("入 ", "In ") + compactTokens(totals.input + totals.cacheRead + totals.cacheWrite)
                    + store.loc(" · 出 ", " · Out ") + compactTokens(totals.output + totals.reasoning)
            )
            .font(.system(size: 9, design: .monospaced))
            .foregroundStyle(.secondary)
            if let hitRate = totals.cacheHitRate {
                Text(store.loc("缓存命中 ", "Cache hit ") + String(format: "%.0f%%", hitRate * 100))
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: - Provider quotas (from local logs, no network)

    @ViewBuilder
    private var rateLimitSection: some View {
        let snapshots = UsageTool.allCases.compactMap { tool -> (UsageTool, RateLimitSnapshot)? in
            guard let snapshot = controller.ledger.rateLimits[tool.rawValue] else { return nil }
            return (tool, snapshot)
        }
        if !snapshots.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(Array(snapshots.enumerated()), id: \.offset) { _, pair in
                    quotaCard(tool: pair.0, snapshot: pair.1)
                }
            }
        }
    }

    private func quotaCard(tool: UsageTool, snapshot: RateLimitSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(
                store.loc("\(tool.displayName) 配额", "\(tool.displayName) Quota"),
                systemImage: "gauge.with.dots.needle.67percent"
            )
            .font(.system(size: 13, weight: .semibold))
            HStack(spacing: 12) {
                ProgressView(value: min(max(snapshot.usedPercent, 0), 100), total: 100)
                    .progressViewStyle(.linear)
                Text(String(format: "%.0f%%", snapshot.usedPercent))
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .frame(width: 40, alignment: .trailing)
            }
            HStack(spacing: 12) {
                if let windowMinutes = snapshot.windowMinutes {
                    Text(windowLabel(minutes: windowMinutes))
                }
                if let resetsAt = snapshot.resetsAt {
                    Text(store.loc("重置：", "Resets: ") + DisplayFormatters.date(resetsAt))
                }
                if let planType = snapshot.planType {
                    Text(store.loc("套餐：", "Plan: ") + planType)
                }
            }
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
            Text(
                store.loc(
                    "来自 \(tool.displayName) 本地会话日志（\(DisplayFormatters.date(snapshot.capturedAt))），未联网查询",
                    "From \(tool.displayName)'s local session logs (\(DisplayFormatters.date(snapshot.capturedAt))); no network request"
                )
            )
            .font(.system(size: 9))
            .foregroundStyle(.tertiary)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .windowBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.secondary.opacity(0.14)))
    }

    private func windowLabel(minutes: Int) -> String {
        if minutes >= 10080 { return store.loc("窗口：每周", "Window: weekly") }
        if minutes >= 1440 { return store.loc("窗口：每日", "Window: daily") }
        return store.loc("窗口：\(minutes / 60) 小时", "Window: \(minutes / 60)h")
    }

    // MARK: - Per-tool cards

    private var toolSection: some View {
        let byTool = UsageAggregation.totalsByTool(files: files, sinceDay: thirtyDaysAgo)
        let tools = UsageTool.allCases.filter { byTool[$0] != nil }
        return VStack(alignment: .leading, spacing: 10) {
            Text(store.loc("工具明细（近 30 日）", "By Tool (Last 30 Days)"))
                .font(.system(size: 13, weight: .semibold))
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), spacing: 12)], spacing: 12) {
                ForEach(tools) { tool in
                    ToolUsageCard(
                        tool: tool,
                        totals: byTool[tool] ?? UsageTotals(),
                        modelTotals: UsageAggregation.totalsByModel(files: files, tool: tool, sinceDay: thirtyDaysAgo),
                        showsCost: store.settings.tokenUsage.showsCostEstimate
                    )
                }
            }
        }
    }

    // MARK: - 30-day trend

    private var trendSection: some View {
        let series = UsageAggregation.dailySeriesByTool(files: files, days: 30)
        return VStack(alignment: .leading, spacing: 10) {
            Text(store.loc("每日用量（近 30 日）", "Daily Usage (Last 30 Days)"))
                .font(.system(size: 13, weight: .semibold))
            VStack(spacing: 4) {
                UsageTrendChart(series: series)
                    .frame(height: 120)
                if let first = series.first, let last = series.last {
                    HStack {
                        Text(DisplayFormatters.shortDay(first.day))
                        Spacer()
                        if series.count > 2 {
                            Text(DisplayFormatters.shortDay(series[series.count / 2].day))
                            Spacer()
                        }
                        Text(DisplayFormatters.shortDay(last.day))
                    }
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.tertiary)
                }
            }
            HStack(spacing: 12) {
                ForEach(UsageTool.allCases) { tool in
                    if series.contains(where: { ($0.byTool[tool]?.total ?? 0) > 0 }) {
                        HStack(spacing: 4) {
                            Circle().fill(toolColor(tool)).frame(width: 6, height: 6)
                            Text(tool.displayName)
                        }
                    }
                }
            }
            .font(.system(size: 9))
            .foregroundStyle(.secondary)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .windowBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.secondary.opacity(0.14)))
    }

    // MARK: - Top sessions

    private var topSessionsSection: some View {
        let rows = UsageAggregation.topFiles(files: files, sinceDay: thirtyDaysAgo)
        return VStack(alignment: .leading, spacing: 10) {
            Text(store.loc("Top 会话（近 30 日）", "Top Sessions (Last 30 Days)"))
                .font(.system(size: 13, weight: .semibold))
            ForEach(rows, id: \.key) { row in
                let path = UsageFileKey.path(of: row.key)
                let deepLinks = row.tool == .claude || row.tool == .codex
                let title =
                    sessionTitles[path].flatMap { $0.isEmpty ? nil : $0 }
                    ?? URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
                HStack(spacing: 8) {
                    Circle().fill(toolColor(row.tool)).frame(width: 6, height: 6)
                    Text(title)
                        .font(.system(size: 11))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Text(compactTokens(row.totals.total))
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                    if deepLinks {
                        Image(systemName: "arrow.right.circle")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.05)))
                .contentShape(Rectangle())
                .onTapGesture {
                    guard deepLinks else { return }
                    store.sessionCenterRequestedSessionID = path
                    store.settings.agentCenterSection = .sessions
                    store.activePanel = .agent
                }
                .helpTip(
                    deepLinks
                        ? store.loc("在 Session Center 中打开", "Open in Session Center")
                        : path
                )
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .windowBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.secondary.opacity(0.14)))
    }

    // MARK: - Empty state & footer

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(store.loc("尚未统计到用量", "No usage recorded yet"))
                .font(.system(size: 13, weight: .semibold))
            Text(
                store.loc(
                    "XFinder 只读取本机各 AI 工具的会话日志（~/.claude、~/.codex、~/.kimi-code、~/.grok 等）。安装并使用过受支持的工具后，点击刷新即可统计。",
                    "XFinder only reads local AI tool logs (~/.claude, ~/.codex, ~/.kimi-code, ~/.grok, …). Use a supported tool, then hit Refresh."
                )
            )
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .windowBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.secondary.opacity(0.14)))
    }

    private var footer: some View {
        Text(
            store.loc(
                "数据全部来自本地日志，token 为精确统计；成本按内置静态价目表估算（≈）。文件被工具清理后，已归档的历史用量仍保留。",
                "All data comes from local logs; token counts are exact, costs are estimates (≈) from a built-in static price list. Usage already recorded survives each tool's own cleanup."
            )
        )
        .font(.system(size: 9))
        .foregroundStyle(.tertiary)
    }

    // MARK: - Formatting

    private func compactTokens(_ value: Int64) -> String {
        switch value {
        case 1_000_000_000...: return String(format: "%.2fB", Double(value) / 1_000_000_000)
        case 1_000_000...: return String(format: "%.1fM", Double(value) / 1_000_000)
        case 10_000...: return String(format: "%.0fK", Double(value) / 1_000)
        case 1_000...: return String(format: "%.1fK", Double(value) / 1_000)
        default: return "\(value)"
        }
    }

    private func compactBytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }
}

func toolColor(_ tool: UsageTool) -> Color {
    switch tool {
    case .claude: return .orange
    case .codex: return .green
    case .kimi: return .blue
    case .grok: return .purple
    case .cursor: return .teal
    case .copilot: return .gray
    case .antigravity: return .red
    case .opencode: return .yellow
    case .glm: return .indigo
    case .doubao: return .pink
    }
}

private struct UsageSummaryCard<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            content()
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 100, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .windowBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.secondary.opacity(0.14)))
    }
}

private struct ToolUsageCard: View {
    let tool: UsageTool
    let totals: UsageTotals
    let modelTotals: [String: UsageTotals]
    let showsCost: Bool
    @State private var expanded = false

    private var cost: (value: Double, complete: Bool) {
        UsageAggregation.costUSD(modelTotals: modelTotals)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                Circle().fill(toolColor(tool)).frame(width: 8, height: 8)
                Text(tool.displayName)
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
                .buttonStyle(.plain)
            }
            HStack(alignment: .firstTextBaseline) {
                Text(compact(totals.total))
                    .font(.system(size: 15, weight: .semibold, design: .monospaced))
                Text("tokens")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                Spacer()
                if showsCost {
                    Text(String(format: "≈ $%.2f", cost.value) + (cost.complete ? "" : "+"))
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 12) {
                smallMetric("In", compact(totals.input + totals.cacheRead + totals.cacheWrite))
                smallMetric("Out", compact(totals.output + totals.reasoning))
                smallMetric("Cache", totals.cacheHitRate.map { String(format: "%.0f%%", $0 * 100) } ?? "—")
            }
            if expanded {
                Divider()
                ForEach(modelTotals.sorted { $0.value.total > $1.value.total }, id: \.key) { model, modelTotals in
                    HStack {
                        Text(model.isEmpty ? "—" : model)
                            .font(.system(size: 10, design: .monospaced))
                            .lineLimit(1)
                        Spacer()
                        Text(compact(modelTotals.total))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .windowBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(toolColor(tool).opacity(0.25)))
    }

    private func smallMetric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.system(size: 8)).foregroundStyle(.tertiary)
            Text(value).font(.system(size: 10, weight: .medium, design: .monospaced))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func compact(_ value: Int64) -> String {
        switch value {
        case 1_000_000_000...: return String(format: "%.2fB", Double(value) / 1_000_000_000)
        case 1_000_000...: return String(format: "%.1fM", Double(value) / 1_000_000)
        case 10_000...: return String(format: "%.0fK", Double(value) / 1_000)
        case 1_000...: return String(format: "%.1fK", Double(value) / 1_000)
        default: return "\(value)"
        }
    }
}

/// Stacked per-tool daily bars over the trailing window. Values are per-day
/// totals; empty days are full-height 2pt baselines so the axis reads clearly.
private struct UsageTrendChart: View {
    let series: [(day: String, byTool: [UsageTool: UsageTotals])]

    var body: some View {
        GeometryReader { proxy in
            let maximum = max(1, series.map { day in day.byTool.values.reduce(0) { $0 + $1.total } }.max() ?? 1)
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(series, id: \.day) { day in
                    let dayTotal = day.byTool.values.reduce(0) { $0 + $1.total }
                    let height =
                        dayTotal > 0
                        ? max(2, proxy.size.height * CGFloat(dayTotal) / CGFloat(maximum))
                        : 2
                    VStack(spacing: 0) {
                        ForEach(UsageTool.allCases) { tool in
                            let toolTotal = day.byTool[tool]?.total ?? 0
                            if toolTotal > 0 {
                                Rectangle()
                                    .fill(toolColor(tool).opacity(0.8))
                                    .frame(height: max(1, height * CGFloat(toolTotal) / CGFloat(dayTotal)))
                            }
                        }
                        if dayTotal == 0 {
                            Rectangle()
                                .fill(Color.secondary.opacity(0.15))
                                .frame(height: 2)
                        }
                    }
                    .help("\(day.day): \(dayTotal) tokens")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        }
        .background(Color.secondary.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}
