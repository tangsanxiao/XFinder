import Foundation

struct TokenUsageNotice: Identifiable, Equatable {
    let id = UUID()
    let zh: String
    let en: String
    let isError: Bool
}

/// Owns the Token Usage panel's state. Follows the NetworkDiagnostics
/// lifecycle: the view calls `activate`/`deactivate` on appear/disappear, so
/// no scanning ever runs while the panel is hidden. Refreshing is incremental
/// (only bytes appended since the last scan are read) and runs on a utility
/// thread; the persisted ledger is shown immediately on activation.
@MainActor
final class TokenUsageController: ObservableObject {
    @Published private(set) var ledger = UsageLedger()
    @Published private(set) var isScanning = false
    @Published private(set) var progress: TokenUsageScanProgress?
    @Published private(set) var lastUpdated: Date?
    @Published var notice: TokenUsageNotice?

    private let ledgerURL: URL
    private var config = TokenUsageConfig()
    private var scanTask: Task<Void, Never>?
    private var autoRefreshTask: Task<Void, Never>?
    private var generation = 0
    private var isActive = false

    init(ledgerURL: URL? = nil) {
        self.ledgerURL =
            ledgerURL
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("XFinder", isDirectory: true)
            .appendingPathComponent("usage-ledger.json")
    }

    func activate(config: TokenUsageConfig) {
        self.config = config
        guard !isActive else { return }
        isActive = true
        // Show the last persisted ledger right away; the refresh then folds in
        // whatever was appended since.
        if let persisted = TokenUsageScanner.loadLedger(at: ledgerURL) {
            ledger = persisted
        }
        refresh()
        startAutoRefreshIfEnabled()
    }

    func deactivate() {
        guard isActive else { return }
        isActive = false
        generation += 1
        scanTask?.cancel()
        scanTask = nil
        autoRefreshTask?.cancel()
        autoRefreshTask = nil
        isScanning = false
    }

    func applyConfig(_ config: TokenUsageConfig) {
        let autoRefreshChanged =
            config.autoRefreshEnabled != self.config.autoRefreshEnabled
            || config.autoRefreshMinutes != self.config.autoRefreshMinutes
        self.config = config
        if isActive, autoRefreshChanged {
            autoRefreshTask?.cancel()
            autoRefreshTask = nil
            startAutoRefreshIfEnabled()
        }
    }

    func refresh() {
        guard isActive, scanTask == nil else { return }
        generation += 1
        let generation = self.generation
        isScanning = true
        progress = nil
        let ledgerURL = ledgerURL
        let retentionDays = config.retentionDays
        emit(zh: "正在扫描各工具的本地会话日志…", en: "Scanning local session logs…")

        scanTask = Task { [weak self] in
            let result = await TokenUsageScanner.scan(
                ledgerURL: ledgerURL,
                retentionDays: retentionDays
            ) { [weak self] progress in
                Task { @MainActor [weak self] in
                    guard let self, self.generation == generation else { return }
                    self.progress = progress
                }
            }
            guard let self, !Task.isCancelled, self.generation == generation else { return }
            self.ledger = result.ledger
            self.isScanning = false
            self.progress = nil
            self.scanTask = nil
            self.lastUpdated = Date()
            self.emit(
                zh:
                    "用量已更新（新读 \(ByteCountFormatter.string(fromByteCount: result.metrics.bytesRead, countStyle: .file))，复用 \(result.metrics.reusedFiles) 个文件）",
                en:
                    "Usage updated (\(ByteCountFormatter.string(fromByteCount: result.metrics.bytesRead, countStyle: .file)) read, \(result.metrics.reusedFiles) files unchanged)"
            )
        }
    }

    /// Auto-refresh is opt-in, clamped to 1…30 minutes, and only runs while
    /// the panel is visible (deactivate cancels the loop).
    private func startAutoRefreshIfEnabled() {
        guard config.autoRefreshEnabled else { return }
        let interval = min(max(config.autoRefreshMinutes, 1), 30)
        autoRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(interval * 60))
                } catch {
                    break
                }
                guard let self, !Task.isCancelled else { break }
                self.refresh()
            }
        }
    }

    private func emit(zh: String, en: String, isError: Bool = false) {
        notice = TokenUsageNotice(zh: zh, en: en, isError: isError)
    }
}
