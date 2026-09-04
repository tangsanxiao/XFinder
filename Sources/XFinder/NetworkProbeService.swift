import CFNetwork
import Foundation

private final class NetworkMetricsCollector: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var collected = NetworkPhaseTimings.empty

    var timings: NetworkPhaseTimings {
        lock.lock()
        defer { lock.unlock() }
        return collected
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didFinishCollecting metrics: URLSessionTaskMetrics
    ) {
        guard let transaction = metrics.transactionMetrics.last else { return }

        func milliseconds(_ start: Date?, _ end: Date?) -> Double? {
            guard let start, let end, end >= start else { return nil }
            return end.timeIntervalSince(start) * 1_000
        }

        let value = NetworkPhaseTimings(
            dnsMs: milliseconds(transaction.domainLookupStartDate, transaction.domainLookupEndDate),
            tcpMs: milliseconds(
                transaction.connectStartDate,
                transaction.secureConnectionStartDate ?? transaction.connectEndDate
            ),
            tlsMs: milliseconds(transaction.secureConnectionStartDate, transaction.secureConnectionEndDate),
            requestMs: milliseconds(transaction.requestStartDate, transaction.requestEndDate),
            ttfbMs: milliseconds(transaction.requestEndDate, transaction.responseStartDate),
            downloadMs: milliseconds(transaction.responseStartDate, transaction.responseEndDate),
            isProxyConnection: transaction.isProxyConnection,
            reusedConnection: transaction.isReusedConnection,
            networkProtocol: transaction.networkProtocolName,
            remoteAddress: transaction.remoteAddress
        )
        lock.lock()
        collected = value
        lock.unlock()
    }
}

actor NetworkProbeService {
    static let maximumResponseBytes = 16 * 1_024

    func probeSeries(target: NetworkProbeTarget, count: Int) async -> NetworkTargetRun {
        var samples: [NetworkProbeSample] = []
        for index in 0..<max(1, count) {
            if Task.isCancelled { break }
            samples.append(await probe(target: target))
            if index + 1 < count {
                try? await Task.sleep(for: .milliseconds(150))
            }
        }
        return NetworkTargetRun(target: target, samples: samples)
    }

    func probe(target: NetworkProbeTarget) async -> NetworkProbeSample {
        let started = NetworkMonotonicClock.now()
        let collector = NetworkMetricsCollector()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 7
        configuration.waitsForConnectivity = false
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        var request = URLRequest(url: target.url)
        request.httpMethod = target.method
        request.timeoutInterval = 5
        request.setValue("XFinder-NetworkDiagnostics/1.0", forHTTPHeaderField: "User-Agent")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        request.setValue("bytes=0-\(Self.maximumResponseBytes - 1)", forHTTPHeaderField: "Range")
        if target.kind == .openAI || target.kind == .claude {
            request.setValue("application/json", forHTTPHeaderField: "Accept")
        }
        if target.kind == .claude {
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        }

        do {
            let (data, response) = try await session.data(for: request, delegate: collector)
            let totalMs = max(0, (NetworkMonotonicClock.now() - started) * 1_000)
            guard let httpResponse = response as? HTTPURLResponse else {
                return NetworkProbeSample(
                    totalMs: totalMs,
                    httpStatus: nil,
                    status: .degraded,
                    summary: "Invalid HTTP response",
                    phases: collector.timings
                )
            }
            let boundedBody = data.prefix(Self.maximumResponseBytes)
            let verdict = NetworkResponseInterpreter.verdict(
                kind: target.kind,
                statusCode: httpResponse.statusCode,
                body: Data(boundedBody)
            )
            return NetworkProbeSample(
                totalMs: totalMs,
                httpStatus: httpResponse.statusCode,
                status: verdict.status,
                summary: verdict.summary,
                errorType: verdict.errorType,
                phases: collector.timings
            )
        } catch is CancellationError {
            return NetworkProbeSample(
                totalMs: max(0, (NetworkMonotonicClock.now() - started) * 1_000),
                httpStatus: nil,
                status: .unreachable,
                summary: "Cancelled"
            )
        } catch {
            return NetworkProbeSample(
                totalMs: max(0, (NetworkMonotonicClock.now() - started) * 1_000),
                httpStatus: nil,
                status: .unreachable,
                summary: Self.errorSummary(error)
            )
        }
    }

    private static func errorSummary(_ error: Error) -> String {
        guard let urlError = error as? URLError else { return error.localizedDescription }
        switch urlError.code {
        case .cannotFindHost, .dnsLookupFailed: return "DNS lookup failed"
        case .cannotConnectToHost: return "Connection failed"
        case .timedOut: return "Timed out"
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate:
            return "TLS validation failed"
        case .notConnectedToInternet: return "No internet connection"
        case .networkConnectionLost: return "Connection lost"
        case .cancelled: return "Cancelled"
        default: return urlError.localizedDescription
        }
    }
}

actor EgressIdentityService {
    func fetch() async -> EgressIdentity? {
        if let identity = await fetchIPInfo() { return identity }
        return await fetchCloudflareTrace()
    }

    private func fetchIPInfo() async -> EgressIdentity? {
        guard let url = URL(string: "https://ipinfo.io/json") else { return nil }
        do {
            let data = try await boundedData(from: url)
            return EgressIdentityParser.parseIPInfo(data)
        } catch {
            return nil
        }
    }

    private func fetchCloudflareTrace() async -> EgressIdentity? {
        guard let url = URL(string: "https://www.cloudflare.com/cdn-cgi/trace") else { return nil }
        guard let data = try? await boundedData(from: url) else { return nil }
        return EgressIdentityParser.parseCloudflareTrace(data)
    }

    private func boundedData(from url: URL) async throws -> Data {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 7
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url)
        request.setValue("XFinder-NetworkDiagnostics/1.0", forHTTPHeaderField: "User-Agent")
        request.setValue("bytes=0-16383", forHTTPHeaderField: "Range")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<400).contains(http.statusCode), data.count <= 16_384
        else {
            throw URLError(.badServerResponse)
        }
        return data
    }
}

enum NetworkProxyReader {
    static func read() -> NetworkProxySnapshot {
        guard let values = CFNetworkCopySystemProxySettings()?.takeRetainedValue() as? [String: Any] else {
            return .none
        }

        func endpoint(enabledKey: String, hostKey: String, portKey: String) -> String? {
            guard (values[enabledKey] as? NSNumber)?.boolValue == true,
                let host = values[hostKey] as? String, !host.isEmpty
            else { return nil }
            let port = (values[portKey] as? NSNumber)?.intValue
            return port.map { "\(host):\($0)" } ?? host
        }

        return NetworkProxySnapshot(
            httpProxy: endpoint(
                enabledKey: kCFNetworkProxiesHTTPEnable as String,
                hostKey: kCFNetworkProxiesHTTPProxy as String,
                portKey: kCFNetworkProxiesHTTPPort as String
            ),
            httpsProxy: endpoint(
                enabledKey: kCFNetworkProxiesHTTPSEnable as String,
                hostKey: kCFNetworkProxiesHTTPSProxy as String,
                portKey: kCFNetworkProxiesHTTPSPort as String
            ),
            socksProxy: endpoint(
                enabledKey: kCFNetworkProxiesSOCKSEnable as String,
                hostKey: kCFNetworkProxiesSOCKSProxy as String,
                portKey: kCFNetworkProxiesSOCKSPort as String
            )
        )
    }
}
