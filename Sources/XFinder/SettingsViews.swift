import SwiftUI

/// App settings sheet (opened from the sidebar gear): language, opt-in Claude
/// integration + CLI path, Debug mode, and the What's New entry. All strings
/// are bilingual via `store.loc`.
struct SettingsView: View {
    @EnvironmentObject private var store: WorkspaceStore
    let onClose: () -> Void
    @State private var showsWhatsNew = false

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
                    summaryLLMSection
                    Divider()
                    claudeSection
                    Divider()
                    debugSection
                    Divider()
                    aboutSection
                }
                .padding(18)
            }
        }
        .frame(width: 520, height: 480)
        .sheet(isPresented: $showsWhatsNew) {
            WhatsNewSheet(onClose: { showsWhatsNew = false })
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

    private var claudeSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(store.loc("Claude 集成", "Claude integration"))
                .font(.system(size: 13, weight: .semibold))

            Toggle(isOn: claudeEnabledBinding) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(store.loc("启用 Claude 集成", "Enable Claude integration"))
                    Text(
                        store.loc(
                            "在面板右键菜单和项目状态卡片中显示 Analyze / Ask / Open in Claude Code。默认关闭。",
                            "Show Analyze / Ask / Open in Claude Code in pane menus and the project status card. Off by default."
                        )
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }

            if store.settings.claudeIntegrationEnabled {
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    Text(store.loc("claude CLI 路径", "claude CLI path"))
                        .font(.system(size: 12, weight: .medium))
                    TextField(
                        store.loc(
                            "留空则用登录 shell 的 PATH 解析 claude", "Leave empty to resolve claude via the login shell PATH"),
                        text: cliPathBinding
                    )
                    .textFieldStyle(.roundedBorder)
                    Text(
                        store.loc(
                            "仅当 claude 不在 PATH 中时才需要填写绝对路径，例如 /opt/homebrew/bin/claude。",
                            "Only needed when claude isn't on PATH, e.g. /opt/homebrew/bin/claude."
                        )
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }

            Text(
                store.loc(
                    "XFinder 不存储任何 API key —— 它复用你本机已安装、已登录的 Claude Code CLI。",
                    "XFinder stores no API key — it reuses the Claude Code CLI already installed and signed in on your Mac."
                )
            )
            .font(.caption)
            .foregroundStyle(.tertiary)
            .padding(.top, 2)
        }
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
                            "在顶部工具栏显示「操作与错误记录」面板，便于排查问题。默认关闭。",
                            "Show the Activity & Errors panel in the top toolbar for troubleshooting. Off by default."
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
            Button {
                showsWhatsNew = true
            } label: {
                Label(store.loc("更新日志 / What's New", "What's New"), systemImage: "clock.arrow.circlepath")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    private var languageBinding: Binding<AppLanguage> {
        Binding(get: { store.settings.language }, set: { store.settings.language = $0 })
    }

    private var debugBinding: Binding<Bool> {
        Binding(get: { store.settings.debugModeEnabled }, set: { store.settings.debugModeEnabled = $0 })
    }

    private var claudeEnabledBinding: Binding<Bool> {
        Binding(get: { store.settings.claudeIntegrationEnabled }, set: { store.settings.claudeIntegrationEnabled = $0 })
    }

    private var cliPathBinding: Binding<String> {
        Binding(get: { store.settings.claudeCLIPath }, set: { store.settings.claudeCLIPath = $0 })
    }
}
