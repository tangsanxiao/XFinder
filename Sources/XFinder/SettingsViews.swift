import SwiftUI

/// App settings and feature overview. Strings are bilingual via `store.loc`.
struct SettingsView: View {
    @EnvironmentObject private var store: WorkspaceStore
    let onClose: () -> Void
    @State private var showsFeatureOverview = false
    @State private var updateCheckInFlight = false
    @State private var updateCheckResult: UpdateCheckResult?
    @State private var diskCapacity: DiskCapacity?

    private enum UpdateCheckResult {
        case upToDate
        case available(ReleaseInfoParsing.Release)
        case failed
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label(store.loc("设置", "Settings"), systemImage: "gearshape")
                    .font(.headline)
                Spacer()
                Button(store.loc("完成", "Done")) { onClose() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(18)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    languageSection
                    Divider()
                    readAloudSection
                    Divider()
                    skillsSection
                    Divider()
                    tokenUsageSection
                    Divider()
                    summaryLLMSection
                    Divider()
                    debugSection
                    Divider()
                    storageSection
                    Divider()
                    aboutSection
                }
                .padding(18)
            }
        }
        .frame(width: 520, height: 480)
        .sheet(isPresented: $showsFeatureOverview) {
            FeatureOverviewSheet(onClose: { showsFeatureOverview = false })
        }
    }

    private var languageSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(store.loc("语言", "Language"))
                .font(.system(size: 13, weight: .semibold))
            Picker("", selection: languageBinding) {
                Text(store.loc("跟随系统", "System")).tag(AppLanguage.system)
                Text("中文").tag(AppLanguage.chinese)
                Text("English").tag(AppLanguage.english)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
    }

    private var skillsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(store.loc("技能库", "Skill library"))
                .font(.system(size: 13, weight: .semibold))
            TextField(
                store.loc("留空则使用 ~/Skills", "Leave empty for ~/Skills"),
                text: skillLibraryBinding
            )
            .textFieldStyle(.roundedBorder)
            Text(
                store.loc(
                    "「收入技能库并链接」会把技能移到这里,并在各 agent 目录建软链接(单一来源,编辑一次处处生效)。",
                    "“Consolidate into library” moves skills here and symlinks them into each agent (single source — edit once, applies everywhere)."
                )
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private var readAloudSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(store.loc("文件朗读", "Read Aloud"))
                .font(.system(size: 13, weight: .semibold))
            Toggle(isOn: doubaoEnabledBinding) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(store.loc("优先使用豆包语音", "Prefer Doubao Speech"))
                    Text(
                        store.loc(
                            "未配置、断网或请求失败时自动使用 macOS 系统语音。",
                            "Uses the macOS system voice when configuration or network requests fail."
                        )
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }

            if store.settings.doubaoTTS.enabled {
                Divider()
                VStack(alignment: .leading, spacing: 4) {
                    Text("API Key").font(.system(size: 12, weight: .medium))
                    SecureField(store.loc("火山引擎语音 API Key", "Volcengine Speech API key"), text: doubaoAPIKeyBinding)
                        .textFieldStyle(.roundedBorder)
                }
                labeledField(
                    store.loc("资源 ID", "Resource ID"),
                    text: doubaoResourceIDBinding,
                    placeholder: "seed-tts-2.0"
                )
                labeledField(
                    store.loc("音色 ID", "Voice ID"),
                    text: doubaoVoiceIDBinding,
                    placeholder: "zh_female_vv_uranus_bigtts"
                )
                HStack(spacing: 8) {
                    Link(
                        destination: URL(string: "https://console.volcengine.com/speech/new/setting/apikeys")!
                    ) {
                        Label(store.loc("获取 API Key", "Get API Key"), systemImage: "arrow.up.right.square")
                    }
                    Spacer()
                    Text(store.loc("凭证仅保存在本机", "Credentials stay on this Mac"))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .font(.caption)
            }
        }
    }

    private var skillLibraryBinding: Binding<String> {
        Binding(get: { store.settings.skillLibraryPath }, set: { store.settings.skillLibraryPath = $0 })
    }

    private var tokenUsageSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(store.loc("Token 用量", "Token Usage"))
                .font(.system(size: 13, weight: .semibold))
            Stepper(
                store.loc(
                    "历史保留 \(store.settings.tokenUsage.retentionDays) 天",
                    "Keep \(store.settings.tokenUsage.retentionDays) days of history"),
                value: retentionDaysBinding,
                in: 30...370,
                step: 30
            )
            Toggle(isOn: autoRefreshBinding) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(store.loc("面板打开时自动刷新", "Auto-refresh while the panel is open"))
                    Text(
                        store.loc(
                            "间隔 1–30 分钟；仅读取各工具日志的新增部分。默认关闭。",
                            "Every 1–30 minutes; only newly appended log bytes are read. Off by default."
                        )
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
            if store.settings.tokenUsage.autoRefreshEnabled {
                Stepper(
                    store.loc(
                        "每 \(store.settings.tokenUsage.autoRefreshMinutes) 分钟",
                        "Every \(store.settings.tokenUsage.autoRefreshMinutes) minutes"),
                    value: autoRefreshMinutesBinding,
                    in: 1...30
                )
            }
            Toggle(isOn: costEstimateBinding) {
                Text(store.loc("显示成本估算", "Show cost estimates"))
            }
            Text(
                store.loc(
                    "统计只读本地日志，不联网；成本按内置价目表估算。",
                    "Usage is read from local logs only, with no network access; costs are estimated from a built-in price list."
                )
            )
            .font(.caption)
            .foregroundStyle(.tertiary)
        }
    }

    private var summaryLLMSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(store.loc("会话总结 LLM", "Session summary LLM"))
                .font(.system(size: 13, weight: .semibold))
            Toggle(isOn: llmEnabledBinding) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(store.loc("启用第三方 LLM 总结", "Enable third-party LLM summaries"))
                    Text(
                        store.loc(
                            "在会话中心用你自己的 OpenAI 兼容接口总结会话。默认关闭。",
                            "Summarize sessions in Session Center via your own OpenAI-compatible endpoint. Off by default."
                        )
                    )
                    .font(.caption).foregroundStyle(.secondary)
                }
            }
            if store.settings.summaryLLM.enabled {
                Divider()
                labeledField(
                    store.loc("接口地址 (Base URL)", "Base URL"), text: llmBaseURLBinding,
                    placeholder: "https://api.openai.com/v1")
                labeledField(store.loc("模型", "Model"), text: llmModelBinding, placeholder: "gpt-4o-mini")
                VStack(alignment: .leading, spacing: 4) {
                    Text("API Key").font(.system(size: 12, weight: .medium))
                    SecureField(store.loc("你的 API Key", "Your API key"), text: llmKeyBinding)
                        .textFieldStyle(.roundedBorder)
                }
                Text(
                    store.loc(
                        "API Key 仅保存在本机的应用设置中,不会上传到除你配置的接口之外的任何地方。",
                        "Your API key is stored locally in the app's settings and sent only to the endpoint you configure."
                    )
                )
                .font(.caption).foregroundStyle(.tertiary)
            }
        }
    }

    private func labeledField(_ label: String, text: Binding<String>, placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.system(size: 12, weight: .medium))
            TextField(placeholder, text: text).textFieldStyle(.roundedBorder)
        }
    }

    private var llmEnabledBinding: Binding<Bool> {
        Binding(get: { store.settings.summaryLLM.enabled }, set: { store.settings.summaryLLM.enabled = $0 })
    }
    private var llmBaseURLBinding: Binding<String> {
        Binding(get: { store.settings.summaryLLM.baseURL }, set: { store.settings.summaryLLM.baseURL = $0 })
    }
    private var llmModelBinding: Binding<String> {
        Binding(get: { store.settings.summaryLLM.model }, set: { store.settings.summaryLLM.model = $0 })
    }
    private var llmKeyBinding: Binding<String> {
        Binding(get: { store.settings.summaryLLM.apiKey }, set: { store.settings.summaryLLM.apiKey = $0 })
    }
    private var doubaoEnabledBinding: Binding<Bool> {
        Binding(get: { store.settings.doubaoTTS.enabled }, set: { store.settings.doubaoTTS.enabled = $0 })
    }
    private var doubaoAPIKeyBinding: Binding<String> {
        Binding(get: { store.settings.doubaoTTS.apiKey }, set: { store.settings.doubaoTTS.apiKey = $0 })
    }
    private var doubaoResourceIDBinding: Binding<String> {
        Binding(get: { store.settings.doubaoTTS.resourceID }, set: { store.settings.doubaoTTS.resourceID = $0 })
    }
    private var doubaoVoiceIDBinding: Binding<String> {
        Binding(get: { store.settings.doubaoTTS.voiceID }, set: { store.settings.doubaoTTS.voiceID = $0 })
    }

    private var debugSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(store.loc("调试", "Debug"))
                .font(.system(size: 13, weight: .semibold))
            Toggle(isOn: debugBinding) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(store.loc("开启 Debug 模式", "Enable Debug mode"))
                    Text(
                        store.loc(
                            "在布局菜单中显示重启应用入口。默认关闭。",
                            "Show Restart App in the layout menu. Off by default."
                        )
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var aboutSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(store.loc("关于", "About"))
                .font(.system(size: 13, weight: .semibold))
            HStack(spacing: 10) {
                Text(
                    store.loc(
                        "版本 \(AppVersionInfo.marketing)（构建 \(AppVersionInfo.build)）",
                        "Version \(AppVersionInfo.marketing) (build \(AppVersionInfo.build))")
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                Button {
                    checkForUpdates()
                } label: {
                    if updateCheckInFlight {
                        ProgressView()
                            .controlSize(.mini)
                    } else {
                        Text(store.loc("检查更新", "Check for Updates"))
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(updateCheckInFlight)
            }
            switch updateCheckResult {
            case .none:
                EmptyView()
            case .upToDate:
                Label(store.loc("已是最新版本", "You're up to date"), systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            case .available(let release):
                HStack(spacing: 6) {
                    Label(
                        store.loc("发现新版本 \(release.tag)", "New version \(release.tag) available"),
                        systemImage: "arrow.down.circle.fill"
                    )
                    .foregroundStyle(.orange)
                    if let url = release.url {
                        Link(store.loc("查看", "View"), destination: url)
                    }
                }
                .font(.caption)
            case .failed:
                Label(
                    store.loc("检查失败，请稍后重试", "Check failed; try again later"),
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.caption)
                .foregroundStyle(.red)
            }
            Button {
                showsFeatureOverview = true
            } label: {
                Label(store.loc("功能简介", "Feature Overview"), systemImage: "info.circle")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            Link("github.com/tangsanxiao/XFinder", destination: FeatureOverviewSheet.repositoryURL)
                .font(.caption)
        }
    }

    private var storageSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(store.loc("存储", "Storage"))
                .font(.system(size: 13, weight: .semibold))
            if let disk = diskCapacity {
                HStack {
                    Label(disk.volumeName, systemImage: "internaldrive")
                        .font(.system(size: 12, weight: .medium))
                    Spacer()
                    Text(store.loc("已用 ", "Used ") + String(format: "%.0f%%", disk.usedFraction * 100))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ProgressView(value: disk.usedFraction)
                    .progressViewStyle(.linear)
                HStack(spacing: 12) {
                    Text(store.loc("共 ", "Total ") + DisplayFormatters.compactSize(disk.totalBytes))
                    Text(store.loc("已用 ", "Used ") + DisplayFormatters.compactSize(disk.usedBytes))
                    Text(store.loc("可用 ", "Available ") + DisplayFormatters.compactSize(disk.availableBytes))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                Text(
                    store.loc(
                        "可用空间包含可清除数据，与 Finder 显示的口径一致。",
                        "Available space includes purgeable data, matching what Finder reports."
                    )
                )
                .font(.caption)
                .foregroundStyle(.tertiary)
            } else {
                Text(store.loc("无法读取磁盘容量", "Could not read disk capacity"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear {
            // Single cheap resource-values read when the panel opens; no polling.
            if diskCapacity == nil {
                diskCapacity = DiskCapacityProbe.systemVolume()
            }
        }
    }

    private func checkForUpdates() {
        updateCheckInFlight = true
        updateCheckResult = nil
        Task {
            defer { updateCheckInFlight = false }
            do {
                let release = try await UpdateChecker.fetchLatestRelease()
                updateCheckResult =
                    ReleaseInfoParsing.isNewer(remote: release.tag, than: AppVersionInfo.marketing)
                    ? .available(release)
                    : .upToDate
            } catch {
                updateCheckResult = .failed
            }
        }
    }

    private var languageBinding: Binding<AppLanguage> {
        Binding(get: { store.settings.language }, set: { store.settings.language = $0 })
    }

    private var debugBinding: Binding<Bool> {
        Binding(get: { store.settings.debugModeEnabled }, set: { store.settings.debugModeEnabled = $0 })
    }

    private var retentionDaysBinding: Binding<Int> {
        Binding(get: { store.settings.tokenUsage.retentionDays }, set: { store.settings.tokenUsage.retentionDays = $0 })
    }
    private var autoRefreshBinding: Binding<Bool> {
        Binding(
            get: { store.settings.tokenUsage.autoRefreshEnabled },
            set: { store.settings.tokenUsage.autoRefreshEnabled = $0 })
    }
    private var autoRefreshMinutesBinding: Binding<Int> {
        Binding(
            get: { store.settings.tokenUsage.autoRefreshMinutes },
            set: { store.settings.tokenUsage.autoRefreshMinutes = $0 })
    }
    private var costEstimateBinding: Binding<Bool> {
        Binding(
            get: { store.settings.tokenUsage.showsCostEstimate },
            set: { store.settings.tokenUsage.showsCostEstimate = $0 })
    }

}
