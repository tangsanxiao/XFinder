import Foundation

private final class BoundedProcessOutput: @unchecked Sendable {
    private let lock = NSLock()
    private let maximumBytes: Int
    private var storage = Data()

    init(maximumBytes: Int = 2 * 1_024 * 1_024) {
        self.maximumBytes = maximumBytes
    }

    func append(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        let remainingBytes = max(0, maximumBytes - storage.count)
        if remainingBytes > 0 {
            storage.append(data.prefix(remainingBytes))
        }
    }

    func snapshot() -> Data {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

enum NetworkQualityRunnerError: LocalizedError {
    case unavailable
    case failed(String)
    case invalidOutput
    case cancelled

    var errorDescription: String? {
        switch self {
        case .unavailable: return "networkQuality is unavailable on this Mac."
        case .failed(let message): return message
        case .invalidOutput: return "networkQuality returned an unreadable result."
        case .cancelled: return "Speed test cancelled."
        }
    }
}

final class NetworkQualityRunner: @unchecked Sendable {
    private let lock = NSLock()
    private var runningProcess: Process?

    func run() async throws -> NetworkQualityResult {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/networkQuality") else {
            throw NetworkQualityRunnerError.unavailable
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let process = Process()
                let output = Pipe()
                let errors = Pipe()
                let outputBuffer = BoundedProcessOutput()
                let errorBuffer = BoundedProcessOutput()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/networkQuality")
                process.arguments = ["-c", "-M", "20"]
                process.standardOutput = output
                process.standardError = errors
                output.fileHandleForReading.readabilityHandler = { handle in
                    outputBuffer.append(handle.availableData)
                }
                errors.fileHandleForReading.readabilityHandler = { handle in
                    errorBuffer.append(handle.availableData)
                }

                process.terminationHandler = { [weak self] finished in
                    output.fileHandleForReading.readabilityHandler = nil
                    errors.fileHandleForReading.readabilityHandler = nil
                    outputBuffer.append(output.fileHandleForReading.readDataToEndOfFile())
                    errorBuffer.append(errors.fileHandleForReading.readDataToEndOfFile())
                    let outputData = outputBuffer.snapshot()
                    let errorData = errorBuffer.snapshot()
                    self?.clear(process: finished)

                    if finished.terminationReason == .uncaughtSignal {
                        continuation.resume(throwing: NetworkQualityRunnerError.cancelled)
                        return
                    }
                    guard finished.terminationStatus == 0 else {
                        let message = String(data: errorData, encoding: .utf8)?
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        continuation.resume(
                            throwing: NetworkQualityRunnerError.failed(
                                message?.isEmpty == false ? message! : "Speed test failed."
                            ))
                        return
                    }
                    guard let result = NetworkQualityParser.parse(outputData) else {
                        continuation.resume(throwing: NetworkQualityRunnerError.invalidOutput)
                        return
                    }
                    continuation.resume(returning: result)
                }

                do {
                    lock.lock()
                    runningProcess = process
                    lock.unlock()
                    try process.run()
                } catch {
                    output.fileHandleForReading.readabilityHandler = nil
                    errors.fileHandleForReading.readabilityHandler = nil
                    clear(process: process)
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            self.cancel()
        }
    }

    func cancel() {
        lock.lock()
        let process = runningProcess
        lock.unlock()
        guard let process, process.isRunning else { return }
        process.terminate()
    }

    private func clear(process: Process) {
        lock.lock()
        if runningProcess === process { runningProcess = nil }
        lock.unlock()
    }
}
