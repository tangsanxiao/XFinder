import Foundation
import Testing

@testable import XFinder

// MARK: - Shadowrocket NetworkUsage archive

@Test func parsesShadowrocketNetworkUsageArchive() throws {
    let dict: [String: Any] = [
        "proxyInBytes": NSNumber(value: 73_798_529_919),
        "proxyOutBytes": NSNumber(value: 18_442_500_000),
        "directInBytes": NSNumber(value: 24_249_498_259),
        "directOutBytes": NSNumber(value: 260_226_600_000),
        "proxyReqs": NSNumber(value: 729_912),
        "directReqs": NSNumber(value: 10_029_284),
        "startTime": NSDate(timeIntervalSince1970: 1_789_000_000),
    ]
    let data = try NSKeyedArchiver.archivedData(withRootObject: dict, requiringSecureCoding: false)

    let usage = ProxyUsageParsing.parseNetworkUsage(data: data)
    #expect(usage?.proxyInBytes == 73_798_529_919)
    #expect(usage?.proxyOutBytes == 18_442_500_000)
    #expect(usage?.directRequests == 10_029_284)
    let unwrapped = try #require(usage)
    #expect(unwrapped.totalProxyBytes == 92_241_029_919)
    #expect(abs(unwrapped.directRequestShare! - 10_029_284.0 / 10_759_196.0) < 1e-9)
}

@Test func networkUsageRejectsGarbage() {
    #expect(ProxyUsageParsing.parseNetworkUsage(data: Data("not a plist".utf8)) == nil)
    #expect(ProxyUsageParsing.parseNetworkUsage(data: Data()) == nil)
}

@Test func directShareIsNilWithoutRequests() {
    #expect(ShadowrocketUsage().directRequestShare == nil)
}

// MARK: - subscription-userinfo header

@Test func parsesSubscriptionUserinfoHeader() throws {
    let parsed = ProxyUsageParsing.parseSubscriptionUserinfo(
        "upload=1534576404; download=52288904853; total=53687091200; expire=1807200000")
    #expect(parsed?.uploadBytes == 1_534_576_404)
    #expect(parsed?.downloadBytes == 52_288_904_853)
    #expect(parsed?.totalBytes == 53_687_091_200)
    let usage = try #require(parsed)
    #expect(usage.usedBytes == 53_823_481_257)
    #expect(usage.expiresAt == Date(timeIntervalSince1970: 1_807_200_000))
    // 50.1 GB used of 50 GB → ~100%.
    #expect(abs(usage.usedFraction! - 1.0) < 0.01)
}

@Test func subscriptionUserinfoToleratesMissingExpireAndWhitespace() {
    let usage = ProxyUsageParsing.parseSubscriptionUserinfo("upload=1 ; download=2; total=10")
    #expect(usage?.usedBytes == 3)
    #expect(usage?.expiresAt == nil)
    #expect(usage?.usedFraction == 0.3)
    #expect(ProxyUsageParsing.parseSubscriptionUserinfo("upload=1") == nil)
    #expect(ProxyUsageParsing.parseSubscriptionUserinfo("") == nil)
}

// MARK: - Subscription URL discovery

@Test func extractsSubscriptionURLFromBinaryBlob() {
    var blob = Data("header-bytes\u{0}\u{1}".utf8)
    blob.append(Data("https://acsub.example.com/?sid=232347&uid=1&token=abcDEF123=&app=auto\u{0}".utf8))
    blob.append(Data("trailing".utf8))
    let url = ProxyUsageParsing.extractSubscriptionURL(from: blob)
    #expect(url?.absoluteString == "https://acsub.example.com/?sid=232347&uid=1&token=abcDEF123=&app=auto")
}

@Test func subscriptionURLSkipsNonCredentialLinks() {
    let blob = Data("see https://example.com/docs and https://sub.example.com/api?token=xyz end".utf8)
    #expect(ProxyUsageParsing.extractSubscriptionURL(from: blob)?.host == "sub.example.com")
    #expect(ProxyUsageParsing.extractSubscriptionURL(from: Data("nothing here".utf8)) == nil)
}

// MARK: - netstat -ib tunnel parsing

@Test func parsesNetstatTunnelInterfaces() {
    let sample = """
        Name  Mtu   Network       Address            Ipkts Ierrs     Ibytes    Opkts Oerrs     Obytes  Coll
        en0   1500  <Link#7>      1c:f6:4c:64:05:89        0     0          0        0     0          0     0
        utun0 1500  <Link#19>                              0     0          0        1     0        100     0
        utun4 1360  <Link#23>                        5448277     0 6342390068  1018941     0  451789622     0
        utun4 1360  10.8/24       10.8.0.6         5448277     - 6342390068  1018941     -  451789622     -
        """
    let tunnels = ProxyUsageParsing.parseTunnelInterfaces(sample)
    #expect(tunnels.count == 2)
    #expect(tunnels[0].name == "utun4")
    #expect(tunnels[0].address == "10.8.0.6")
    #expect(tunnels[0].bytesIn == 6_342_390_068)
    #expect(tunnels[0].bytesOut == 451_789_622)
    // The no-address row is only kept when no addressed row exists.
    #expect(tunnels[1].name == "utun0")
    #expect(tunnels[1].address == nil)
    #expect(tunnels[1].bytesOut == 100)
}

@Test func netstatParsingIgnoresNonTunnelsAndIdleInterfaces() {
    let sample = """
        Name  Mtu   Network       Address            Ipkts Ierrs     Ibytes    Opkts Oerrs     Obytes  Coll
        en1   1500  192.168.31/24 192.168.31.206     100     0     50000      100     0     50000     0
        utun2 2000  <Link#21>                              0     0          0        0     0          0     0
        """
    #expect(ProxyUsageParsing.parseTunnelInterfaces(sample).isEmpty)
}
