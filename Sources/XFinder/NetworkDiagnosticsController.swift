import Foundation

struct NetworkDiagnosticsNotice: Identifiable, Equatable {
    let id = UUID()
    let zh: String
    let en: String
    let isError: Bool
}

@MainActor
final class NetworkDiagnosticsController: ObservableObject {
    @Published private(set) var runs: [String: NetworkTargetRun] = [:]
    @Published private(set) var egressIdentity: EgressIdentity?
    @Published private(set) var pathSnapshot = NetworkPathSnapshot.unknown
    @Published private(set) var proxySnapshot = NetworkProxySnapshot.none
    @Published private(set) var currentTraffic = NetworkTrafficRate.zero
    @Published private(set) var trafficHistory: [NetworkTrafficRate] = []
    @Published private(set) var isChecking = false
    @Published private(set) var checkProgress = 0.0
    @Published private(set) var isMonitoring = false
    @Published private(set) var monitoringDeadline: Date?
    @Published private(set) var isSpeedTesting = false
    @Published private(set) var qualityResult: NetworkQualityResult?
    @Published private(set) var notice: NetworkDiagnosticsNotice?

    private let probeService = NetworkProbeService()
    private let identityService = EgressIdentityService()
    private let pathObserver = NetworkPathObserver()
    private let qualityRunner = NetworkQualityRunner()
    private var trafficTask: Task<Void, Never>?
    private var checkTask: Task<Void, Never>?
    private var monitoringTask: Task<Void, Never>?
    private var qualityTask: Task<Void, Never>?
    private var operationGeneration = 0
    private var isActive = false

    var isBusy: Bool { isChecking || isMonitoring || isSpeedTesting }

    func activate() {
        guard !isActive else { return }
        isActive = true
        pathObserver.start { [weak self] snapshot in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let pathChanged =
                    pathSnapshot != .unknown
                    && (pathSnapshot.interfaceNames != snapshot.interfaceNames
                        || pathSnapshot.isSatisfied != snapshot.isSatisfied)
                pathSnapshot = snapshot
                if pathChanged {
                    egressIdentity = nil
                    emit(
                        zh: "网络路径已改变，请重新检测出口与节点状态。",
                        en: "The network path changed. Run the check again to refresh the route and endpoints."
                    )
                }
            }
        }
        proxySnapshot = NetworkProxyReader.read()
        startTrafficSampling()
    }

    func deactivate() {
        guard isActive else { return }
        isActive = false
        pathObserver.stop()
        trafficTask?.cancel()
        trafficTask = nil
        stopOperations(announce: false)
    }

    func runQuickCheck(targets: [NetworkProbeTarget]) {
        guard !targets.isEmpty else { return }
        stopOperations(announce: false)
        operationGeneration += 1
        let generation = operationGeneration
        isChecking = true
        checkProgress = 0
        proxySnapshot = NetworkProxyReader.read()
        emit(zh: "正在检测 \(targets.count) 个网络节点…", en: "Checking \(targets.count) network endpoints…")

        checkTask = Task { [weak self] in
            guard let self else { return }
            async let identity = identityService.fetch()
            await performProbePass(targets: targets, samplesPerTarget: 5, generation: generation)
            let fetchedIdentity = await identity
            guard !Task.isCancelled, operationGeneration == generation else { return }
            egressIdentity = fetchedIdentity
            isChecking = false
            checkProgress = 1
            emit(zh: "网络检测完成。", en: "Network check completed.")
        }
    }

    func startMonitoring(targets: [NetworkProbeTarget], interval: TimeInterval, duration: TimeInterval) {
        guard !targets.isEmpty else { return }
        stopOperations(announce: false)
        operationGeneration += 1
        let generation = operationGeneration
        let safeInterval = min(max(interval, 5), 60)
        let safeDuration = min(max(duration, 60), 600)
        isMonitoring = true
        let deadline = Date().addingTimeInterval(safeDuration)
        monitoringDeadline = deadline
        emit(zh: "稳定性监测已开始，最长运行 10 分钟。", en: "Stability monitoring started for up to 10 minutes.")

        monitoringTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled, Date() < deadline, operationGeneration == generation {
                await performProbePass(targets: targets, samplesPerTarget: 1, generation: generation)
                guard !Task.isCancelled, Date() < deadline, operationGeneration == generation else { break }
                do {
                    try await Task.sleep(for: .seconds(safeInterval))
                } catch {
                    break
                }
            }
            guard operationGeneration == generation else { return }
            isMonitoring = false
            monitoringDeadline = nil
            monitoringTask = nil
            if !Task.isCancelled {
                emit(zh: "稳定性监测已完成。", en: "Stability monitoring completed.")
            }
        }
    }

    func stopMonitoring() {
        guard isMonitoring else { return }
        operationGeneration += 1
        monitoringTask?.cancel()
        monitoringTask = nil
        isMonitoring = false
        monitoringDeadline = nil
        emit(zh: "稳定性监测已停止。", en: "Stability monitoring stopped.")
    }

    func runSpeedTest() {
        stopOperations(announce: false)
        isSpeedTesting = true
        qualityResult = nil
        emit(
            zh: "正在运行完整测速；这可能消耗数百 MB 流量…",
            en: "Running the full speed test; it may use several hundred MB of data…"
        )
        qualityTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await qualityRunner.run()
                guard !Task.isCancelled else { return }
                qualityResult = result
                isSpeedTesting = false
                qualityTask = nil
                emit(zh: "完整测速已完成。", en: "Full speed test completed.")
            } catch NetworkQualityRunnerError.cancelled {
                isSpeedTesting = false
                qualityTask = nil
            } catch {
                isSpeedTesting = false
                qualityTask = nil
                emit(
                    zh: "完整测速失败：\(error.localizedDescription)",
                    en: "Full speed test failed: \(error.localizedDescription)",
                    isError: true
                )
            }
        }
    }

    func stopSpeedTest() {
        guard isSpeedTesting else { return }
        qualityTask?.cancel()
        qualityTask = nil
        qualityRunner.cancel()
        isSpeedTesting = false
        emit(zh: "完整测速已取消。", en: "Full speed test cancelled.")
    }

    func removeResults(for targetID: String) {
        runs.removeValue(forKey: targetID)
    }

    private func performProbePass(
        targets: [NetworkProbeTarget],
        samplesPerTarget: Int,
        generation: Int
    ) async {
        var completed = 0
        for start in stride(from: 0, to: targets.count, by: 3) {
            guard !Task.isCancelled, operationGeneration == generation else { return }
            let batch = Array(targets[start..<min(start + 3, targets.count)])
            await withTaskGroup(of: NetworkTargetRun.self) { group in
                for target in batch {
                    group.addTask { [probeService] in
                        await probeService.probeSeries(target: target, count: samplesPerTarget)
                    }
                }
                for await run in group {
                    guard !Task.isCancelled, operationGeneration == generation else {
                        group.cancelAll()
                        return
                    }
                    merge(run)
                    completed += 1
                    if isChecking {
                        checkProgress = Double(completed) / Double(targets.count)
                    }
                }
            }
        }
    }

    private func merge(_ newRun: NetworkTargetRun) {
        var run = runs[newRun.id] ?? NetworkTargetRun(target: newRun.target, samples: [])
        for sample in newRun.samples {
            run.append(sample)
        }
        runs[newRun.id] = run
    }

    private func startTrafficSampling() {
        trafficTask?.cancel()
        trafficTask = Task { [weak self] in
            var tracker = NetworkInterfaceDeltaTracker()
            while !Task.isCancelled {
                let counters = await Task.detached(priority: .utility) {
                    NetworkInterfaceCounterReader.read()
                }.value
                if let rate = tracker.accept(counters, at: NetworkMonotonicClock.now()), let self {
                    currentTraffic = rate
                    trafficHistory.append(rate)
                    if trafficHistory.count > 60 {
                        trafficHistory.removeFirst(trafficHistory.count - 60)
                    }
                }
                do {
                    try await Task.sleep(for: .seconds(1))
                } catch {
                    break
                }
            }
        }
    }

    private func stopOperations(announce: Bool) {
        operationGeneration += 1
        checkTask?.cancel()
        monitoringTask?.cancel()
        qualityTask?.cancel()
        qualityRunner.cancel()
        checkTask = nil
        monitoringTask = nil
        qualityTask = nil
        isChecking = false
        isMonitoring = false
        isSpeedTesting = false
        monitoringDeadline = nil
        if announce {
            emit(zh: "网络任务已停止。", en: "Network task stopped.")
        }
    }

    private func emit(zh: String, en: String, isError: Bool = false) {
        notice = NetworkDiagnosticsNotice(zh: zh, en: en, isError: isError)
    }
}
