import Foundation

enum EgressIdentityParser {
    private struct IPInfoResponse: Decodable {
        let ip: String
        let city: String?
        let region: String?
        let country: String?
        let org: String?
    }

    static func parseIPInfo(_ data: Data) -> EgressIdentity? {
        guard let response = try? JSONDecoder().decode(IPInfoResponse.self, from: data) else { return nil }
        return EgressIdentity(
            ip: response.ip,
            city: response.city,
            region: response.region,
            countryCode: response.country,
            organization: response.org,
            source: "ipinfo.io"
        )
    }

    static func parseCloudflareTrace(_ data: Data) -> EgressIdentity? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        var values: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
            if parts.count == 2 { values[parts[0]] = parts[1] }
        }
        guard let ip = values["ip"] else { return nil }
        return EgressIdentity(
            ip: ip,
            city: nil,
            region: values["colo"],
            countryCode: values["loc"],
            organization: nil,
            source: "Cloudflare trace"
        )
    }
}

enum NetworkQualityParser {
    private struct Payload: Decodable {
        let dlThroughput: Double
        let ulThroughput: Double
        let baseRTT: Double?
        let responsiveness: Double?
        let interfaceName: String?
        let testEndpoint: String?
        let downloadedBytes: Int64?
        let uploadedBytes: Int64?

        private enum CodingKeys: String, CodingKey {
            case dlThroughput = "dl_throughput"
            case ulThroughput = "ul_throughput"
            case baseRTT = "base_rtt"
            case responsiveness
            case interfaceName = "interface_name"
            case testEndpoint = "test_endpoint"
            case downloadedBytes = "dl_bytes_transferred"
            case uploadedBytes = "ul_bytes_transferred"
        }
    }

    static func parse(_ data: Data, date: Date = Date()) -> NetworkQualityResult? {
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data) else { return nil }
        return NetworkQualityResult(
            downloadMbps: payload.dlThroughput / 1_000_000,
            uploadMbps: payload.ulThroughput / 1_000_000,
            idleRTTMs: payload.baseRTT,
            responsivenessRPM: payload.responsiveness,
            interfaceName: payload.interfaceName,
            endpoint: payload.testEndpoint,
            downloadedBytes: payload.downloadedBytes,
            uploadedBytes: payload.uploadedBytes,
            date: date
        )
    }
}
