import SwiftUI

struct NetworkStatusView: View {
    @EnvironmentObject private var store: WorkspaceStore
    @ObservedObject var controller: NetworkDiagnosticsController
    let isSidebarVisible: Bool

    @State private var showsAddTarget = false
    @State private var showsSpeedConfirmation = false

    private var targets: [NetworkProbeTarget] {
        NetworkProbeTarget.builtIn
            + store.settings.networkDiagnostics.customTargets.compactMap(NetworkProbeTarget.custom)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    overview
                    nodeSection
                    speedTestSection
                }
                .padding(16)
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .onAppear {
            controller.activate()
            if controller.runs.isEmpty, !controller.isChecking {
                controller.runQuickCheck(targets: targets)
            }
        }
        .onDisappear { controller.deactivate() }
        .onChange(of: controller.notice) { newNotice in
            guard let newNotice else { return }
            let message = store.loc(newNotice.zh, newNotice.en)
            if newNotice.isError {
                store.lastError = message
            } else {
                store.statusMessage = message
            }
        }
        .sheet(isPresented: $showsAddTarget) {
            AddNetworkTargetSheet { target in
                guard store.settings.networkDiagnostics.customTargets.count < 8 else {
                    store.lastError = store.loc("最多可添加 8 个自定义节点。", "You can add up to 8 custom endpoints.")
                    return
                }
                store.settings.networkDiagnostics.customTargets.append(target)
                if let probeTarget = NetworkProbeTarget.custom(target) {
                    controller.runQuickCheck(targets: [probeTarget])
                }
            }
            .environmentObject(store)
        }
        .alert(store.loc("运行完整测速？", "Run full speed test?"), isPresented: $showsSpeedConfirmation) {
            Button(store.loc("取消", "Cancel"), role: .cancel) {}
            Button(store.loc("开始测速", "Run Test")) { controller.runSpeedTest() }
        } message: {
            Text(
                store.loc(
                    "测速由 macOS networkQuality 完成，通常持续约 20 秒，并可能消耗数百 MB 流量。它测量公网综合带宽，不代表到 OpenAI 或 Claude 的专属带宽。",
                    "macOS networkQuality performs this test. It usually takes about 20 seconds and may use several hundred MB. It measures general internet capacity, not dedicated bandwidth to OpenAI or Claude."
                ))
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Label(store.loc("网络状态", "Network Status"), systemImage: "network")
                .font(.system(size: 15, weight: .semibold))
            if controller.isChecking {
                ProgressView(value: controller.checkProgress)
                    .progressViewStyle(.linear)
                    .frame(width: 90)
            } else if controller.isMonitoring {
                Label(store.loc("监测中", "Monitoring"), systemImage: "waveform.path.ecg")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.blue)
            }
            Spacer()
            Button {
                showsAddTarget = true
            } label: {
                Label(store.loc("添加节点", "Add Endpoint"), systemImage: "plus")
            }
            .controlSize(.small)

            if controller.isMonitoring {
                Button {
                    controller.stopMonitoring()
                } label: {
                    Label(store.loc("停止监测", "Stop Monitoring"), systemImage: "stop.fill")
                }
                .controlSize(.small)
            } else {
                Button {
                    controller.startMonitoring(
                        targets: targets,
                        interval: store.settings.networkDiagnostics.monitorIntervalSeconds,
                        duration: store.settings.networkDiagnostics.monitorDurationSeconds
                    )
                } label: {
                    Label(store.loc("稳定性监测", "Stability Monitor"), systemImage: "waveform.path.ecg")
                }
                .controlSize(.small)
                .disabled(controller.isBusy)
            }

            Button {
                controller.runQuickCheck(targets: targets)
            } label: {
                Label(store.loc("快速检测", "Quick Check"), systemImage: "arrow.clockwise")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(controller.isBusy)
        }
        .padding(.leading, isSidebarVisible ? 14 : 112)
        .padding(.trailing, 14)
        .frame(height: 44)
    }

    private var overview: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
            connectionCard
            identityCard
            trafficCard
        }
    }

    private var connectionCard: some View {
        NetworkSummaryCard(
            title: store.loc("当前路径", "Current Path"), systemImage: "point.3.connected.trianglepath.dotted"
        ) {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(controller.pathSnapshot.isSatisfied ? Color.green : Color.red)
                        .frame(width: 7, height: 7)
                    Text(
                        controller.pathSnapshot.isSatisfied
                            ? store.loc("网络可用", "Network available") : store.loc("网络不可用", "No network path")
                    )
                    .font(.system(size: 12, weight: .medium))
                }
                Text(pathDescription)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                if controller.pathSnapshot.hasVPN || controller.proxySnapshot.isEnabled {
                    Label(
                        routeOverlayDescription,
                        systemImage: "shield.lefthalf.filled"
                    )
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.orange)
                    .lineLimit(1)
                }
            }
        }
    }

    private var identityCard: some View {
        NetworkSummaryCard(title: store.loc("出口 IP 与地区", "Egress IP & Region"), systemImage: "globe.asia.australia") {
            if let identity = controller.egressIdentity {
                VStack(alignment: .leading, spacing: 6) {
                    Text(identity.ip)
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                        .textSelection(.enabled)
                    Text(
                        identity.locationLabel.isEmpty ? store.loc("位置未知", "Unknown location") : identity.locationLabel
                    )
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    if let organization = identity.organization, !organization.isEmpty {
                        Text(organization)
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                    HStack(spacing: 5) {
                        regionBadge(.openAI, countryCode: identity.countryCode)
                        regionBadge(.claude, countryCode: identity.countryCode)
                    }
                    Text("≈ \(identity.source) · \(NetworkRegionPolicy.snapshotDate)")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
            } else {
                Text(
                    controller.isChecking
                        ? store.loc("正在查询出口 IP…", "Looking up the egress IP…")
                        : store.loc("运行快速检测以查询", "Run Quick Check to look it up")
                )
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            }
        }
    }

    private var trafficCard: some View {
        NetworkSummaryCard(title: store.loc("当前流量", "Live Traffic"), systemImage: "arrow.up.arrow.down") {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 12) {
                    Label(formatRate(controller.currentTraffic.downloadBytesPerSecond), systemImage: "arrow.down")
                        .foregroundStyle(.blue)
                    Label(formatRate(controller.currentTraffic.uploadBytesPerSecond), systemImage: "arrow.up")
                        .foregroundStyle(.green)
                }
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                TrafficSparkline(samples: controller.trafficHistory)
                    .frame(height: 36)
                Text(store.loc("物理网卡实时流量，不等于可用带宽", "Physical-interface traffic, not available capacity"))
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var nodeSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(store.loc("核心节点", "Core Endpoints"))
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Text(store.loc("401 表示 API 已到达但需要认证", "401 means the API was reached and requires authentication"))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), spacing: 12)], spacing: 12) {
                ForEach(targets) { target in
                    NetworkNodeCard(
                        target: target,
                        run: controller.runs[target.id],
                        identity: controller.egressIdentity,
                        chinese: store.settings.language.isChineseResolved,
                        delete: target.kind == .custom ? { deleteCustomTarget(target.id) } : nil
                    )
                }
            }
            HStack(spacing: 12) {
                Text(
                    store.loc(
                        "地区判断来自随版本更新的官方名单快照：", "Region checks use an official-list snapshot shipped with XFinder:")
                )
                .foregroundStyle(.tertiary)
                Link("OpenAI", destination: URL(string: "https://help.openai.com/en/articles/5347006")!)
                Link("Claude", destination: URL(string: "https://platform.claude.com/docs/en/api/supported-regions")!)
            }
            .font(.system(size: 9))
        }
    }

    private var speedTestSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(store.loc("完整测速", "Full Speed Test"))
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                if controller.isSpeedTesting {
                    Button(store.loc("取消测速", "Cancel Test")) { controller.stopSpeedTest() }
                        .controlSize(.small)
                } else {
                    Button {
                        showsSpeedConfirmation = true
                    } label: {
                        Label(store.loc("运行 networkQuality", "Run networkQuality"), systemImage: "speedometer")
                    }
                    .controlSize(.small)
                    .disabled(
                        controller.isBusy || controller.pathSnapshot.isExpensive
                            || controller.pathSnapshot.isConstrained
                    )
                    .help(
                        controller.pathSnapshot.isExpensive || controller.pathSnapshot.isConstrained
                            ? store.loc(
                                "热点或低数据模式下不运行完整测速", "Full speed tests are disabled on metered or constrained paths")
                            : ""
                    )
                }
            }

            if controller.isSpeedTesting {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text(store.loc("正在测量下载、上传和负载响应性…", "Measuring download, upload, and loaded responsiveness…"))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 60)
            } else if let result = controller.qualityResult {
                HStack(spacing: 10) {
                    qualityMetric(store.loc("下载", "Download"), String(format: "%.1f Mbps", result.downloadMbps))
                    qualityMetric(store.loc("上传", "Upload"), String(format: "%.1f Mbps", result.uploadMbps))
                    qualityMetric(
                        store.loc("空闲 RTT", "Idle RTT"),
                        result.idleRTTMs.map { String(format: "%.0f ms", $0) } ?? "—"
                    )
                    qualityMetric(
                        store.loc("响应性", "Responsiveness"),
                        result.responsivenessRPM.map { String(format: "%.0f RPM", $0) } ?? "—"
                    )
                }
                if let detail = qualityDetail(result) {
                    Text(detail).font(.system(size: 9)).foregroundStyle(.tertiary)
                }
            } else {
                Text(
                    store.loc(
                        "按需测量公网综合带宽。节点卡片中的延迟与抖动才代表到对应服务的路径质量。",
                        "Measure general internet capacity on demand. Endpoint latency and jitter above represent each service path."
                    )
                )
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .windowBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.secondary.opacity(0.14)))
    }

    private var pathDescription: String {
        let types = controller.pathSnapshot.interfaceTypes.filter { $0 != "Loopback" }
        let typeLabel = types.isEmpty ? store.loc("接口未知", "Unknown interface") : types.joined(separator: " / ")
        let protocols = [
            controller.pathSnapshot.supportsIPv4 ? "IPv4" : nil, controller.pathSnapshot.supportsIPv6 ? "IPv6" : nil,
        ]
        .compactMap { $0 }.joined(separator: " + ")
        return protocols.isEmpty ? typeLabel : "\(typeLabel) · \(protocols)"
    }

    private var routeOverlayDescription: String {
        if controller.pathSnapshot.hasVPN, controller.proxySnapshot.isEnabled {
            return store.loc("VPN 与系统代理已启用", "VPN and system proxy enabled")
        }
        if controller.pathSnapshot.hasVPN { return store.loc("VPN 隧道已启用", "VPN tunnel enabled") }
        return store.loc(
            "系统代理：\(controller.proxySnapshot.summary ?? "—")",
            "System proxy: \(controller.proxySnapshot.summary ?? "—")")
    }

    private func regionBadge(_ service: NetworkServicePolicy, countryCode: String?) -> some View {
        let availability = NetworkRegionPolicy.availability(countryCode: countryCode, service: service)
        let name = service == .openAI ? "OpenAI" : "Claude"
        let detail: (String, Color)
        switch availability {
        case .supported: detail = (store.loc("支持", "Supported"), .green)
        case .notListed: detail = (store.loc("地区风险", "Region risk"), .orange)
        case .unknown: detail = (store.loc("未知", "Unknown"), .secondary)
        }
        return Text("\(name) · \(detail.0)")
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(detail.1)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(detail.1.opacity(0.12)))
    }

    private func qualityMetric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 9)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 14, weight: .semibold, design: .monospaced))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.secondary.opacity(0.06)))
    }

    private func qualityDetail(_ result: NetworkQualityResult) -> String? {
        var values: [String] = []
        if let interfaceName = result.interfaceName {
            values.append(store.loc("接口 \(interfaceName)", "Interface \(interfaceName)"))
        }
        if let endpoint = result.endpoint { values.append(endpoint) }
        let bytes = (result.downloadedBytes ?? 0) + (result.uploadedBytes ?? 0)
        if bytes > 0 {
            values.append(
                store.loc(
                    "流量 \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))",
                    "Data \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))"))
        }
        return values.isEmpty ? nil : values.joined(separator: " · ")
    }

    private func deleteCustomTarget(_ targetID: String) {
        guard let uuid = UUID(uuidString: String(targetID.dropFirst("custom-".count))) else { return }
        store.settings.networkDiagnostics.customTargets.removeAll { $0.id == uuid }
        controller.removeResults(for: targetID)
        store.statusMessage = store.loc("已删除自定义网络节点。", "Custom network endpoint removed.")
    }

    private func formatRate(_ bytesPerSecond: Double) -> String {
        "\(ByteCountFormatter.string(fromByteCount: Int64(max(0, bytesPerSecond)), countStyle: .file))/s"
    }
}

private struct NetworkSummaryCard<Content: View>: View {
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
        .frame(maxWidth: .infinity, minHeight: 132, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .windowBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.secondary.opacity(0.14)))
    }
}

private struct NetworkNodeCard: View {
    let target: NetworkProbeTarget
    let run: NetworkTargetRun?
    let identity: EgressIdentity?
    let chinese: Bool
    let delete: (() -> Void)?
    @State private var expanded = false

    private var latest: NetworkProbeSample? { run?.latest }
    private var statistics: NetworkSampleStatistics? { run?.statistics }
    private func loc(_ zh: String, _ en: String) -> String { chinese ? zh : en }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                Circle().fill(statusColor).frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: 1) {
                    Text(chinese ? target.nameZH : target.nameEN)
                        .font(.system(size: 12, weight: .semibold))
                    Text(target.url.host ?? target.url.absoluteString)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                Spacer()
                if let delete {
                    Button(action: delete) {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .help(loc("删除节点", "Remove endpoint"))
                }
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
                Text(statusText)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(statusColor)
                Spacer()
                Text(latencyText)
                    .font(.system(size: 15, weight: .semibold, design: .monospaced))
            }

            HStack(spacing: 12) {
                smallMetric(loc("成功", "Success"), successText)
                smallMetric("P95", milliseconds(statistics?.p95Ms))
                smallMetric(loc("抖动", "Jitter"), milliseconds(statistics?.jitterMs))
            }

            NodeSparkline(samples: run?.samples ?? [], color: statusColor)
                .frame(height: 28)

            if target.kind == .openAI || target.kind == .claude {
                policyLine
            }

            if expanded, let latest {
                Divider()
                HStack(spacing: 10) {
                    phase("DNS", latest.phases.dnsMs)
                    phase("TCP", latest.phases.tcpMs)
                    phase("TLS", latest.phases.tlsMs)
                    phase("TTFB", latest.phases.ttfbMs)
                }
                HStack(spacing: 6) {
                    if let code = latest.httpStatus { Text("HTTP \(code)") }
                    if let networkProtocol = latest.phases.networkProtocol { Text(networkProtocol.uppercased()) }
                    if latest.phases.isProxyConnection { Text(loc("经代理", "Proxied")) }
                    if NetworkAddressLogic.isProxyFakeIP(latest.phases.remoteAddress) {
                        Text("Fake-IP")
                    }
                }
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.tertiary)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .windowBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(statusColor.opacity(0.25)))
    }

    private var statusText: String {
        guard let latest else { return loc("等待检测", "Not checked") }
        switch latest.status {
        case .reachable: return loc("已连通", "Reachable")
        case .authenticationRequired: return loc("已连通 · 需要认证", "Reachable · Authentication required")
        case .regionRestricted: return loc("接口报告地区限制", "API reports a region restriction")
        case .degraded: return loc("服务异常 · \(latest.summary)", "Degraded · \(latest.summary)")
        case .unreachable: return loc("不可达 · \(latest.summary)", "Unreachable · \(latest.summary)")
        }
    }

    private var statusColor: Color {
        guard let latest else { return .secondary }
        switch latest.status {
        case .reachable, .authenticationRequired: return .green
        case .regionRestricted, .unreachable: return .red
        case .degraded: return .orange
        }
    }

    private var latencyText: String {
        guard let value = statistics?.medianMs else { return "—" }
        return String(format: value >= 1_000 ? "%.2f s" : "%.0f ms", value >= 1_000 ? value / 1_000 : value)
    }

    private var successText: String {
        guard let statistics else { return "—" }
        return String(format: "%.0f%%", statistics.successRate * 100)
    }

    private var policyLine: some View {
        let service: NetworkServicePolicy = target.kind == .openAI ? .openAI : .claude
        let availability = NetworkRegionPolicy.availability(countryCode: identity?.countryCode, service: service)
        let value: (String, Color)
        switch availability {
        case .supported: value = (loc("出口地区在官方支持名单中", "Egress region is on the official support list"), .green)
        case .notListed: value = (loc("出口地区未列入官方支持名单", "Egress region is not on the official support list"), .orange)
        case .unknown: value = (loc("尚无法判断出口地区", "Egress region is not known yet"), .secondary)
        }
        return Label(value.0, systemImage: availability == .supported ? "checkmark.shield" : "exclamationmark.shield")
            .font(.system(size: 9, weight: .medium))
            .foregroundStyle(value.1)
    }

    private func smallMetric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.system(size: 8)).foregroundStyle(.tertiary)
            Text(value).font(.system(size: 10, weight: .medium, design: .monospaced))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func phase(_ title: String, _ value: Double?) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.system(size: 8)).foregroundStyle(.tertiary)
            Text(milliseconds(value)).font(.system(size: 9, weight: .medium, design: .monospaced))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func milliseconds(_ value: Double?) -> String {
        value.map { String(format: "%.0f ms", $0) } ?? "—"
    }
}

private struct NodeSparkline: View {
    let samples: [NetworkProbeSample]
    let color: Color

    var body: some View {
        GeometryReader { proxy in
            let values = samples.suffix(60).map(\.totalMs)
            Path { path in
                guard let minimum = values.min(), let maximum = values.max(), values.count > 1 else { return }
                let range = max(1, maximum - minimum)
                for (index, value) in values.enumerated() {
                    let x = proxy.size.width * CGFloat(index) / CGFloat(values.count - 1)
                    let y = proxy.size.height * (1 - CGFloat((value - minimum) / range))
                    if index == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
                }
            }
            .stroke(color.opacity(0.8), style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
        }
        .background(Color.secondary.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}

private struct TrafficSparkline: View {
    let samples: [NetworkTrafficRate]

    var body: some View {
        GeometryReader { proxy in
            let values = samples.suffix(60)
            let maximum = max(1, values.flatMap { [$0.downloadBytesPerSecond, $0.uploadBytesPerSecond] }.max() ?? 1)
            trafficPath(values.map(\.downloadBytesPerSecond), maximum: maximum, size: proxy.size)
                .stroke(Color.blue.opacity(0.8), lineWidth: 1.4)
            trafficPath(values.map(\.uploadBytesPerSecond), maximum: maximum, size: proxy.size)
                .stroke(Color.green.opacity(0.8), lineWidth: 1.2)
        }
        .background(Color.secondary.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    private func trafficPath(_ values: [Double], maximum: Double, size: CGSize) -> Path {
        Path { path in
            guard values.count > 1 else { return }
            for (index, value) in values.enumerated() {
                let x = size.width * CGFloat(index) / CGFloat(values.count - 1)
                let y = size.height * (1 - CGFloat(value / maximum))
                if index == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
            }
        }
    }
}

private struct AddNetworkTargetSheet: View {
    @EnvironmentObject private var store: WorkspaceStore
    @Environment(\.dismiss) private var dismiss
    let save: (CustomNetworkTarget) -> Void
    @State private var name = ""
    @State private var urlString = "https://"
    @State private var validationMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(store.loc("添加网络节点", "Add Network Endpoint"), systemImage: "network.badge.shield.half.filled")
                .font(.headline)
            TextField(store.loc("名称", "Name"), text: $name)
                .textFieldStyle(.roundedBorder)
            TextField("https://example.com/health", text: $urlString)
                .textFieldStyle(.roundedBorder)
            Text(
                store.loc(
                    "自定义节点使用 HEAD 请求，不上传文件或凭据。HTTP 4xx 仍表示服务器可达。",
                    "Custom endpoints use HEAD requests and upload no files or credentials. An HTTP 4xx still proves the server was reached."
                )
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            if let validationMessage {
                Text(validationMessage).font(.caption).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button(store.loc("取消", "Cancel"), role: .cancel) { dismiss() }
                Button(store.loc("添加", "Add")) { validateAndSave() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 420)
    }

    private func validateAndSave() {
        let target = CustomNetworkTarget(name: name, urlString: urlString)
        guard NetworkProbeTarget.custom(target) != nil else {
            validationMessage = store.loc("请输入有效的 HTTP 或 HTTPS 地址。", "Enter a valid HTTP or HTTPS URL.")
            return
        }
        save(target)
        dismiss()
    }
}
