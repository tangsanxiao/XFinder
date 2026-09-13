import Foundation

/// Shadowrocket's cumulative traffic counters, read from its local
/// `NetworkUsage` file (keyed-archive plist). Read-only; the file format is
/// private to Shadowrocket, so every consumer must degrade gracefully when
/// the layout changes.
struct ShadowrocketUsage: Equatable, Sendable {
    var proxyInBytes: Int64 = 0
    var proxyOutBytes: Int64 = 0
    var directInBytes: Int64 = 0
    var directOutBytes: Int64 = 0
    var proxyRequests: Int64 = 0
    var directRequests: Int64 = 0

    var totalProxyBytes: Int64 { proxyInBytes + proxyOutBytes }
    var totalDirectBytes: Int64 { directInBytes + directOutBytes }

    /// Share of requests answered directly (nil when nothing recorded yet).
    var directRequestShare: Double? {
        let total = proxyRequests + directRequests
        guard total > 0 else { return nil }
        return Double(directRequests) / Double(total)
    }
}

/// Provider-side quota from a subscription's `subscription-userinfo`
/// response header: `upload=…; download=…; total=…; expire=…` (bytes, epoch).
struct SubscriptionUsage: Equatable, Sendable {
    var uploadBytes: Int64
    var downloadBytes: Int64
    var totalBytes: Int64
    var expiresAt: Date?

    var usedBytes: Int64 { uploadBytes + downloadBytes }

    var usedFraction: Double? {
        guard totalBytes > 0 else { return nil }
        return min(1, max(0, Double(usedBytes) / Double(totalBytes)))
    }
}

/// One network tunnel interface's byte counters (from `netstat -ib`),
/// accumulated since the interface came up — this is how OpenVPN and other
/// VPN clients' traffic is surfaced without reading their private files.
struct TunnelInterface: Equatable, Sendable, Identifiable {
    var id: String { name }
    let name: String
    let address: String?
    let bytesIn: Int64
    let bytesOut: Int64
}

enum ProxyUsageParsing {
    // MARK: - Shadowrocket NetworkUsage (NSKeyedArchiver bplist)

    static func parseNetworkUsage(data: Data) -> ShadowrocketUsage? {
        let classes: [AnyClass] = [NSDictionary.self, NSArray.self, NSNumber.self, NSString.self, NSDate.self]
        guard let dict = try? NSKeyedUnarchiver.unarchivedObject(ofClasses: classes, from: data) as? [String: Any]
        else { return nil }
        func int64(_ key: String) -> Int64 { (dict[key] as? NSNumber)?.int64Value ?? 0 }
        return ShadowrocketUsage(
            proxyInBytes: int64("proxyInBytes"),
            proxyOutBytes: int64("proxyOutBytes"),
            directInBytes: int64("directInBytes"),
            directOutBytes: int64("directOutBytes"),
            proxyRequests: int64("proxyReqs"),
            directRequests: int64("directReqs")
        )
    }

    // MARK: - subscription-userinfo header

    /// "upload=1; download=2; total=3; expire=1700000000" → usage. Requires
    /// at least upload+download+total; `expire` is optional.
    static func parseSubscriptionUserinfo(_ header: String) -> SubscriptionUsage? {
        var fields: [String: Int64] = [:]
        for part in header.split(separator: ";") {
            let pair = part.split(separator: "=", maxSplits: 1)
            guard pair.count == 2 else { continue }
            let key = pair[0].trimmingCharacters(in: .whitespaces)
            fields[key] = Int64(pair[1].trimmingCharacters(in: .whitespaces))
        }
        guard let upload = fields["upload"], let download = fields["download"], let total = fields["total"]
        else { return nil }
        return SubscriptionUsage(
            uploadBytes: upload,
            downloadBytes: download,
            totalBytes: total,
            expiresAt: fields["expire"].map { Date(timeIntervalSince1970: TimeInterval($0)) }
        )
    }

    // MARK: - Subscription URL discovery (Shadowrocket's ServerManager blob)

    /// Scans raw bytes for an http(s) URL that looks like a subscription
    /// link (carries credentials such as `sid=`/`token=`). Shadowrocket
    /// stores these inside a keyed archive, so plain string scanning of the
    /// binary is the stable option.
    static func extractSubscriptionURL(from data: Data) -> URL? {
        let text = String(decoding: data, as: UTF8.self)
        let scalars = CharacterSet.urlQueryAllowed
            .union(.urlHostAllowed)
            .union(.urlPathAllowed)
            .union(CharacterSet(charactersIn: ":/?&=%"))
        var best: String?
        var index = text.startIndex
        while let range = text.range(of: "https://", range: index..<text.endIndex) {
            var end = range.upperBound
            while end < text.endIndex, text[end].unicodeScalars.allSatisfy(scalars.contains) {
                end = text.index(after: end)
            }
            let candidate = String(text[range.lowerBound..<end])
            if candidate.contains("sid=") || candidate.contains("token=") {
                best = candidate
                break
            }
            index = range.upperBound
        }
        return best.flatMap { URL(string: $0) }
    }

    // MARK: - netstat -ib

    /// Parses `netstat -ib` output. Rows come in two shapes per interface
    /// (with/without an address column value); the address row wins. Only
    /// tunnel interfaces with real traffic are returned, sorted by volume.
    static func parseTunnelInterfaces(_ text: String) -> [TunnelInterface] {
        var byName: [String: TunnelInterface] = [:]
        for line in text.split(separator: "\n") {
            let tokens = line.split(separator: " ", omittingEmptySubsequences: true)
            // With address: name mtu network address ipkts ierrs ibytes opkts oerrs obytes … (11+)
            // Without:        name mtu network         ipkts ierrs ibytes opkts oerrs obytes … (10+)
            guard tokens.count >= 10, let name = tokens.first, name.hasPrefix("utun") else { continue }
            let hasAddress = tokens.count >= 11
            guard let bytesIn = Int64(tokens[hasAddress ? 6 : 5]),
                let bytesOut = Int64(tokens[hasAddress ? 9 : 8])
            else { continue }
            guard bytesIn + bytesOut > 0 else { continue }
            let address = hasAddress ? String(tokens[3]) : nil
            let candidate = TunnelInterface(
                name: String(name), address: address, bytesIn: bytesIn, bytesOut: bytesOut)
            if let existing = byName[candidate.name], existing.address != nil { continue }
            byName[candidate.name] = candidate
        }
        return byName.values.sorted { $0.bytesIn + $0.bytesOut > $1.bytesIn + $1.bytesOut }
    }
}
