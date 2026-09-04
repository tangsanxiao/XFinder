import Foundation

enum NetworkTargetKind: String, Codable, Sendable {
    case openAI
    case claude
    case domestic
    case custom
}

struct CustomNetworkTarget: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    var name: String
    var urlString: String

    init(id: UUID = UUID(), name: String, urlString: String) {
        self.id = id
        self.name = name
        self.urlString = urlString
    }
}

struct NetworkDiagnosticsConfig: Codable, Equatable, Sendable {
    var customTargets: [CustomNetworkTarget] = []
    var monitorIntervalSeconds: Double = 10
    var monitorDurationSeconds: Double = 600
}

struct NetworkProbeTarget: Identifiable, Equatable, Hashable, Sendable {
    let id: String
    let nameZH: String
    let nameEN: String
    let url: URL
    let kind: NetworkTargetKind
    let method: String

    static let builtIn: [NetworkProbeTarget] = [
        NetworkProbeTarget(
            id: "openai-api",
            nameZH: "OpenAI API",
            nameEN: "OpenAI API",
            url: URL(string: "https://api.openai.com/v1/models")!,
            kind: .openAI,
            method: "GET"
        ),
        NetworkProbeTarget(
            id: "claude-api",
            nameZH: "Claude API",
            nameEN: "Claude API",
            url: URL(string: "https://api.anthropic.com/v1/models")!,
            kind: .claude,
            method: "GET"
        ),
        NetworkProbeTarget(
            id: "baidu",
            nameZH: "百度",
            nameEN: "Baidu",
            url: URL(string: "https://www.baidu.com/favicon.ico")!,
            kind: .domestic,
            method: "GET"
        ),
        NetworkProbeTarget(
            id: "tencent",
            nameZH: "腾讯",
            nameEN: "Tencent",
            url: URL(string: "https://www.qq.com/favicon.ico")!,
            kind: .domestic,
            method: "GET"
        ),
    ]

    static func custom(_ target: CustomNetworkTarget) -> NetworkProbeTarget? {
        let trimmed = target.urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(),
            scheme == "https" || scheme == "http", url.host != nil
        else { return nil }
        let name = target.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return NetworkProbeTarget(
            id: "custom-\(target.id.uuidString)",
            nameZH: name.isEmpty ? url.host! : name,
            nameEN: name.isEmpty ? url.host! : name,
            url: url,
            kind: .custom,
            method: "HEAD"
        )
    }
}

enum NetworkProbeStatus: String, Sendable {
    case reachable
    case authenticationRequired
    case regionRestricted
    case degraded
    case unreachable

    var isSuccessful: Bool {
        self == .reachable || self == .authenticationRequired
    }
}

struct NetworkPhaseTimings: Equatable, Sendable {
    var dnsMs: Double?
    var tcpMs: Double?
    var tlsMs: Double?
    var requestMs: Double?
    var ttfbMs: Double?
    var downloadMs: Double?
    var isProxyConnection: Bool
    var reusedConnection: Bool
    var networkProtocol: String?
    var remoteAddress: String?

    static let empty = NetworkPhaseTimings(isProxyConnection: false, reusedConnection: false)
}

struct NetworkResponseVerdict: Equatable, Sendable {
    let status: NetworkProbeStatus
    let summary: String
    let errorType: String?
}

struct NetworkProbeSample: Identifiable, Equatable, Sendable {
    let id: UUID
    let timestamp: Date
    let totalMs: Double
    let httpStatus: Int?
    let status: NetworkProbeStatus
    let summary: String
    let errorType: String?
    let phases: NetworkPhaseTimings

    init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        totalMs: Double,
        httpStatus: Int?,
        status: NetworkProbeStatus,
        summary: String,
        errorType: String? = nil,
        phases: NetworkPhaseTimings = .empty
    ) {
        self.id = id
        self.timestamp = timestamp
        self.totalMs = totalMs
        self.httpStatus = httpStatus
        self.status = status
        self.summary = summary
        self.errorType = errorType
        self.phases = phases
    }
}

struct NetworkSampleStatistics: Equatable, Sendable {
    let sampleCount: Int
    let successRate: Double
    let medianMs: Double?
    let p95Ms: Double?
    let jitterMs: Double?
    let minimumMs: Double?
    let maximumMs: Double?

    static func calculate(_ samples: [NetworkProbeSample]) -> NetworkSampleStatistics {
        let successful = samples.filter { $0.status.isSuccessful }.map(\.totalMs).sorted()
        guard !samples.isEmpty else {
            return NetworkSampleStatistics(
                sampleCount: 0,
                successRate: 0,
                medianMs: nil,
                p95Ms: nil,
                jitterMs: nil,
                minimumMs: nil,
                maximumMs: nil
            )
        }
        guard !successful.isEmpty else {
            return NetworkSampleStatistics(
                sampleCount: samples.count,
                successRate: 0,
                medianMs: nil,
                p95Ms: nil,
                jitterMs: nil,
                minimumMs: nil,
                maximumMs: nil
            )
        }

        let median: Double
        if successful.count.isMultiple(of: 2) {
            median = (successful[successful.count / 2 - 1] + successful[successful.count / 2]) / 2
        } else {
            median = successful[successful.count / 2]
        }
        let p95Index = min(successful.count - 1, Int(ceil(Double(successful.count) * 0.95)) - 1)
        let mean = successful.reduce(0, +) / Double(successful.count)
        let variance = successful.reduce(0) { $0 + pow($1 - mean, 2) } / Double(successful.count)

        return NetworkSampleStatistics(
            sampleCount: samples.count,
            successRate: Double(successful.count) / Double(samples.count),
            medianMs: median,
            p95Ms: successful[p95Index],
            jitterMs: sqrt(variance),
            minimumMs: successful.first,
            maximumMs: successful.last
        )
    }
}

struct NetworkTargetRun: Identifiable, Equatable, Sendable {
    let target: NetworkProbeTarget
    var samples: [NetworkProbeSample]

    var id: String { target.id }
    var latest: NetworkProbeSample? { samples.last }
    var statistics: NetworkSampleStatistics { .calculate(samples) }

    mutating func append(_ sample: NetworkProbeSample, limit: Int = 120) {
        samples.append(sample)
        if samples.count > limit {
            samples.removeFirst(samples.count - limit)
        }
    }
}

struct EgressIdentity: Equatable, Sendable {
    let ip: String
    let city: String?
    let region: String?
    let countryCode: String?
    let organization: String?
    let source: String

    var locationLabel: String {
        [city, region, countryCode].compactMap { value in
            guard let value, !value.isEmpty else { return nil }
            return value
        }.joined(separator: ", ")
    }
}

struct NetworkPathSnapshot: Equatable, Sendable {
    var isSatisfied: Bool
    var interfaceNames: [String]
    var interfaceTypes: [String]
    var supportsIPv4: Bool
    var supportsIPv6: Bool
    var supportsDNS: Bool
    var isExpensive: Bool
    var isConstrained: Bool

    static let unknown = NetworkPathSnapshot(
        isSatisfied: false,
        interfaceNames: [],
        interfaceTypes: [],
        supportsIPv4: false,
        supportsIPv6: false,
        supportsDNS: false,
        isExpensive: false,
        isConstrained: false
    )

    var hasVPN: Bool {
        interfaceNames.contains { name in
            name.hasPrefix("utun") || name.hasPrefix("ipsec") || name.hasPrefix("ppp")
        }
    }
}

struct NetworkProxySnapshot: Equatable, Sendable {
    let httpProxy: String?
    let httpsProxy: String?
    let socksProxy: String?

    var isEnabled: Bool { httpProxy != nil || httpsProxy != nil || socksProxy != nil }
    var summary: String? { httpsProxy ?? httpProxy ?? socksProxy }

    static let none = NetworkProxySnapshot(httpProxy: nil, httpsProxy: nil, socksProxy: nil)
}

struct NetworkTrafficRate: Identifiable, Equatable, Sendable {
    let timestamp: Date
    let downloadBytesPerSecond: Double
    let uploadBytesPerSecond: Double

    var id: Date { timestamp }
    static let zero = NetworkTrafficRate(timestamp: Date(), downloadBytesPerSecond: 0, uploadBytesPerSecond: 0)
}

struct NetworkQualityResult: Equatable, Sendable {
    let downloadMbps: Double
    let uploadMbps: Double
    let idleRTTMs: Double?
    let responsivenessRPM: Double?
    let interfaceName: String?
    let endpoint: String?
    let downloadedBytes: Int64?
    let uploadedBytes: Int64?
    let date: Date
}
