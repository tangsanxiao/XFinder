import Foundation

/// Read-only collectors for proxy/tunnel usage shown in Network Status.
/// Everything is offline except `fetchSubscriptionUsage`, which runs only
/// when the user taps the button. Shadowrocket's container files are a
/// private format, so every read degrades to nil instead of throwing.
enum ProxyUsageService {
    private static var shadowrocketGroupContainer: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Group Containers/group.com.liguangming.Shadowrocket")
    }

    static var isShadowrocketInstalled: Bool {
        FileManager.default.fileExists(atPath: shadowrocketGroupContainer.path)
    }

    static func shadowrocketUsage() -> ShadowrocketUsage? {
        let url = shadowrocketGroupContainer.appendingPathComponent("NetworkUsage")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return ProxyUsageParsing.parseNetworkUsage(data: data)
    }

    /// The subscription URL embedded in Shadowrocket's server list; only ever
    /// sent back to its own host when the user explicitly queries the quota.
    static func shadowrocketSubscriptionURL() -> URL? {
        let url = shadowrocketGroupContainer.appendingPathComponent("ServerManager")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return ProxyUsageParsing.extractSubscriptionURL(from: data)
    }

    /// User-initiated quota check. GET (not HEAD) because some providers omit
    /// the header on HEAD; the body is a small server list and is discarded.
    static func fetchSubscriptionUsage(from url: URL) async throws -> SubscriptionUsage {
        let request = URLRequest(url: url, timeoutInterval: 15)
        let (data, response) = try await URLSession.shared.data(for: request)
        _ = data
        guard let http = response as? HTTPURLResponse else { throw ProxyUsageError.noUsageHeader }
        let header =
            http.value(forHTTPHeaderField: "subscription-userinfo")
            ?? http.value(forHTTPHeaderField: "Subscription-Userinfo")
        guard let header, let usage = ProxyUsageParsing.parseSubscriptionUserinfo(header) else {
            throw ProxyUsageError.noUsageHeader
        }
        return usage
    }

    /// Byte counters of active tunnel interfaces (OpenVPN, WireGuard, etc.)
    /// since each tunnel came up.
    static func tunnelInterfaces() -> [TunnelInterface] {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/netstat")
        process.arguments = ["-ib"]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        guard let _ = try? process.run() else { return [] }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return [] }
        return ProxyUsageParsing.parseTunnelInterfaces(String(decoding: data, as: UTF8.self))
    }

    enum ProxyUsageError: Error {
        case noUsageHeader
    }
}
