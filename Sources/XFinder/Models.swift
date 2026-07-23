import Foundation

struct DirectoryItem: Identifiable, Codable, Hashable {
    var id: UUID
    var name: String
    var path: String
    var isOpen: Bool

    init(id: UUID = UUID(), name: String, path: String, isOpen: Bool = false) {
        self.id = id
        self.name = name
        self.path = path
        self.isOpen = isOpen
    }
}

struct Workspace: Identifiable, Codable, Hashable {
    var id: UUID
    var name: String
    var layout: WorkspaceLayout
    var directories: [DirectoryItem]

    init(
        id: UUID = UUID(),
        name: String,
        layout: WorkspaceLayout = .grid,
        directories: [DirectoryItem] = []
    ) {
        self.id = id
        self.name = name
        self.layout = layout
        self.directories = directories
    }
}

struct StarItem: Identifiable, Codable, Hashable {
    var id: UUID
    var name: String
    var path: String

    init(id: UUID = UUID(), name: String, path: String) {
        self.id = id
        self.name = name
        self.path = path
    }
}

struct PaneDestination: Identifiable, Hashable {
    let id: UUID
    let name: String
    let url: URL
}

struct FileTask: Identifiable, Equatable {
    let id: UUID
    var title: String
    var detail: String
    var isCancellable: Bool
}

struct SystemBookmark: Identifiable, Hashable {
    let id: String
    let title: String
    let systemImage: String
    let url: URL
}

/// App-wide settings persisted to settings.json. Claude integration is off by
/// default so the default file-manager experience stays clean; users who want
/// the agent features opt in.
enum AppLanguage: String, Codable, CaseIterable, Identifiable {
    case system
    case chinese
    case english

    var id: String { rawValue }

    /// Resolves to the concrete language; `.system` follows the OS preference.
    var isChineseResolved: Bool {
        switch self {
        case .chinese: return true
        case .english: return false
        case .system:
            return Locale.preferredLanguages.first?.lowercased().hasPrefix("zh") ?? false
        }
    }
}

struct AppSettings: Codable, Equatable {
    var claudeIntegrationEnabled = false
    /// Empty = resolve `claude` via the login shell's PATH. A custom path is
    /// used verbatim when the CLI isn't on PATH.
    var claudeCLIPath = ""
    /// When on, the top toolbar shows the Activity & Errors (trace) button.
    var debugModeEnabled = false
    var language: AppLanguage = .system
    /// Canonical skill library directory; empty = default `~/Skills`. Skills
    /// consolidated here are symlinked into each agent (one source of truth).
    var skillLibraryPath = ""
    /// Third-party LLM (OpenAI-compatible) for Session Center summaries.
    var summaryLLM = SummaryLLMConfig()
    /// Optional cloud voice for Read Aloud. System speech remains the default
    /// and is always available as the fallback.
    var doubaoTTS = DoubaoTTSConfig()

    private enum CodingKeys: String, CodingKey {
        case claudeIntegrationEnabled
        case claudeCLIPath
        case debugModeEnabled
        case language
        case skillLibraryPath
        case summaryLLM
        case doubaoTTS
    }

    init() {}

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        claudeIntegrationEnabled = try container.decodeIfPresent(Bool.self, forKey: .claudeIntegrationEnabled) ?? false
        claudeCLIPath = try container.decodeIfPresent(String.self, forKey: .claudeCLIPath) ?? ""
        debugModeEnabled = try container.decodeIfPresent(Bool.self, forKey: .debugModeEnabled) ?? false
        language = try container.decodeIfPresent(AppLanguage.self, forKey: .language) ?? .system
        skillLibraryPath = try container.decodeIfPresent(String.self, forKey: .skillLibraryPath) ?? ""
        summaryLLM = try container.decodeIfPresent(SummaryLLMConfig.self, forKey: .summaryLLM) ?? SummaryLLMConfig()
        doubaoTTS = try container.decodeIfPresent(DoubaoTTSConfig.self, forKey: .doubaoTTS) ?? DoubaoTTSConfig()
    }
}

/// User-configured OpenAI-compatible LLM for summarizing sessions. Off by
/// default; the key is the user's own, stored locally in the app's settings.
struct SummaryLLMConfig: Codable, Equatable {
    var enabled = false
    /// API base, e.g. https://api.openai.com/v1 (no trailing /chat/completions).
    var baseURL = "https://api.openai.com/v1"
    var model = "gpt-4o-mini"
    var apiKey = ""

    var isUsable: Bool {
        enabled && !apiKey.trimmingCharacters(in: .whitespaces).isEmpty
            && !baseURL.trimmingCharacters(in: .whitespaces).isEmpty
            && !model.trimmingCharacters(in: .whitespaces).isEmpty
    }
}

/// User-owned credentials for Volcengine Doubao Speech. The current V3 API
/// accepts one API key plus a resource and speaker identifier.
struct DoubaoTTSConfig: Codable, Equatable, Sendable {
    var enabled = false
    var apiKey = ""
    var resourceID = "seed-tts-2.0"
    var voiceID = "zh_female_vv_uranus_bigtts"

    var isUsable: Bool {
        enabled && !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !resourceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !voiceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// Coarse, rule-based file classification (no LLM) for the pane's category
/// filter — built for the AI-agent workflow where a run leaves behind docs,
/// logs, scripts, and build/dependency noise mixed together.
enum FileCategory: String, CaseIterable, Identifiable {
    case folder
    case document
    case code
    case data
    case image
    case archive
    case log
    case noise  // build output / dependency dirs / temp artifacts
    case other

    var id: String { rawValue }

    func title(chinese: Bool) -> String {
        switch self {
        case .folder: return chinese ? "文件夹" : "Folders"
        case .document: return chinese ? "文档" : "Documents"
        case .code: return chinese ? "代码" : "Code"
        case .data: return chinese ? "数据/配置" : "Data / Config"
        case .image: return chinese ? "图片" : "Images"
        case .archive: return chinese ? "压缩包" : "Archives"
        case .log: return chinese ? "日志" : "Logs"
        case .noise: return chinese ? "构建/依赖噪音" : "Build / Dependency noise"
        case .other: return chinese ? "其他" : "Other"
        }
    }

    var systemImage: String {
        switch self {
        case .folder: "folder"
        case .document: "doc.text"
        case .code: "chevron.left.forwardslash.chevron.right"
        case .data: "tablecells"
        case .image: "photo"
        case .archive: "archivebox"
        case .log: "scroll"
        case .noise: "trash"
        case .other: "doc"
        }
    }
}

enum BrowserSortKey: String, Codable {
    case name
    case modified
    case kind

    var defaultAscending: Bool {
        switch self {
        case .name, .kind:
            return true
        case .modified:
            return false
        }
    }
}

/// A pane's sort column + direction, persisted per pane so it survives
/// workspace switches (which destroy and recreate panes).
struct PaneSortOrder: Codable, Equatable {
    var key: BrowserSortKey = .name
    var ascending: Bool = true
}

enum BrowserViewMode: String, CaseIterable, Identifiable {
    case icons
    case list
    case columns

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .icons: "square.grid.2x2"
        case .list: "list.bullet"
        case .columns: "rectangle.split.3x1"
        }
    }

    var title: String {
        switch self {
        case .icons: "Icons"
        case .list: "List"
        case .columns: "Columns"
        }
    }
}

enum WorkspaceLayout: String, CaseIterable, Codable, Identifiable {
    case single
    case columns2
    case columns3
    case rows3
    case grid
    case mainAndStack

    var id: String { rawValue }

    var title: String {
        switch self {
        case .single: "Single"
        case .columns2: "Two Columns"
        case .columns3: "Three Columns"
        case .rows3: "Three Rows"
        case .grid: "Grid"
        case .mainAndStack: "Main + Stack"
        }
    }

    var systemImage: String {
        switch self {
        case .single: "rectangle"
        case .columns2: "rectangle.split.2x1"
        case .columns3: "rectangle.split.3x1"
        case .rows3: "rectangle.stack"
        case .grid: "square.grid.2x2"
        case .mainAndStack: "rectangle.leadinghalf.inset.filled"
        }
    }

    /// How many panes this layout is meant to show. `nil` means "show whatever
    /// folders exist" (Main + Stack adapts to the folder count).
    var preferredPaneCount: Int? {
        switch self {
        case .single: return 1
        case .columns2: return 2
        case .columns3, .rows3: return 3
        case .grid: return 4
        case .mainAndStack: return nil
        }
    }

    /// The layout that best fits a given number of panes — used to auto-adjust
    /// when a pane is closed.
    static func fitting(paneCount: Int) -> WorkspaceLayout {
        switch paneCount {
        case ...1: return .single
        case 2: return .columns2
        case 3: return .columns3
        default: return .grid
        }
    }

    /// Number of columns the pane grid uses.
    var gridColumns: Int {
        switch self {
        case .single, .rows3: return 1
        case .columns2: return 2
        case .columns3: return 3
        case .grid: return 2
        case .mainAndStack: return 1
        }
    }
}

enum WorkspaceStoreError: LocalizedError {
    case noSelectedWorkspace
    case appleScript(String)

    var errorDescription: String? {
        switch self {
        case .noSelectedWorkspace:
            return "No workspace is selected."
        case .appleScript(let message):
            return message
        }
    }
}
