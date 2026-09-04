import Foundation
import Testing

@testable import XFinder

@Test func networkStatisticsCalculatesMedianP95JitterAndSuccessRate() {
    let samples =
        [10.0, 20.0, 30.0, 40.0].map {
            NetworkProbeSample(
                totalMs: $0,
                httpStatus: 200,
                status: .reachable,
                summary: "OK"
            )
        } + [
            NetworkProbeSample(
                totalMs: 5_000,
                httpStatus: nil,
                status: .unreachable,
                summary: "Timed out"
            )
        ]

    let statistics = NetworkSampleStatistics.calculate(samples)

    #expect(statistics.sampleCount == 5)
    #expect(statistics.successRate == 0.8)
    #expect(statistics.medianMs == 25)
    #expect(statistics.p95Ms == 40)
    #expect(statistics.minimumMs == 10)
    #expect(statistics.maximumMs == 40)
    #expect(abs((statistics.jitterMs ?? 0) - 11.1803) < 0.001)
}

@Test func expectedAPIAuthorizationFailuresCountAsReachable() {
    let body = Data(#"{"error":{"type":"authentication_error","message":"missing key"}}"#.utf8)
    let openAI = NetworkResponseInterpreter.verdict(kind: .openAI, statusCode: 401, body: body)
    let claude = NetworkResponseInterpreter.verdict(kind: .claude, statusCode: 401, body: body)

    #expect(openAI.status == .authenticationRequired)
    #expect(claude.status == .authenticationRequired)
    #expect(openAI.status.isSuccessful)
}

@Test func explicitRegionErrorsAreSeparateFromPolicyInference() {
    let body = Data(
        #"{"error":{"code":"unsupported_country_region_territory","message":"unsupported region"}}"#.utf8
    )
    let verdict = NetworkResponseInterpreter.verdict(kind: .openAI, statusCode: 403, body: body)

    #expect(verdict.status == .regionRestricted)
    #expect(!verdict.status.isSuccessful)
    #expect(NetworkRegionPolicy.availability(countryCode: "US", service: .openAI) == .supported)
    #expect(NetworkRegionPolicy.availability(countryCode: "CN", service: .openAI) == .notListed)
    #expect(NetworkRegionPolicy.availability(countryCode: "CN", service: .claude) == .notListed)
    #expect(NetworkRegionPolicy.availability(countryCode: nil, service: .claude) == .unknown)
}

@Test func responseClassificationDistinguishesServiceAndCustomFailures() {
    #expect(NetworkResponseInterpreter.verdict(kind: .openAI, statusCode: 529, body: Data()).status == .degraded)
    #expect(NetworkResponseInterpreter.verdict(kind: .custom, statusCode: 404, body: Data()).status == .reachable)
    #expect(NetworkResponseInterpreter.verdict(kind: .domestic, statusCode: 404, body: Data()).status == .degraded)
}

@Test func proxyFakeIPDetectionOnlyMatchesBenchmarkRange() {
    #expect(NetworkAddressLogic.isProxyFakeIP("198.18.0.34"))
    #expect(NetworkAddressLogic.isProxyFakeIP("198.19.255.254"))
    #expect(!NetworkAddressLogic.isProxyFakeIP("198.20.0.1"))
    #expect(!NetworkAddressLogic.isProxyFakeIP("1.1.1.1"))
}

@Test func customEndpointValidationRequiresHTTPAndHost() {
    #expect(
        NetworkProbeTarget.custom(CustomNetworkTarget(name: "Health", urlString: "https://example.com/health")) != nil)
    #expect(NetworkProbeTarget.custom(CustomNetworkTarget(name: "Local file", urlString: "file:///tmp/a")) == nil)
    #expect(NetworkProbeTarget.custom(CustomNetworkTarget(name: "Broken", urlString: "https://")) == nil)
}

@Test func egressParsersHandlePrimaryAndFallbackShapes() throws {
    let ipInfo = Data(
        #"{"ip":"203.0.113.9","city":"Tokyo","region":"Tokyo","country":"JP","org":"AS64500 Example"}"#.utf8
    )
    let primary = try #require(EgressIdentityParser.parseIPInfo(ipInfo))
    #expect(primary.ip == "203.0.113.9")
    #expect(primary.countryCode == "JP")
    #expect(primary.organization == "AS64500 Example")

    let trace = Data("fl=1\nip=198.51.100.4\nloc=SG\ncolo=SIN\n".utf8)
    let fallback = try #require(EgressIdentityParser.parseCloudflareTrace(trace))
    #expect(fallback.countryCode == "SG")
    #expect(fallback.region == "SIN")
}

@Test func networkQualityParserConvertsBitsPerSecondToMegabits() throws {
    let date = Date(timeIntervalSince1970: 100)
    let data = Data(
        """
        {
          "dl_throughput": 640000000,
          "ul_throughput": 42000000,
          "base_rtt": 31.5,
          "responsiveness": 620,
          "interface_name": "en1",
          "test_endpoint": "example.test",
          "dl_bytes_transferred": 1000000,
          "ul_bytes_transferred": 200000
        }
        """.utf8
    )
    let result = try #require(NetworkQualityParser.parse(data, date: date))

    #expect(result.downloadMbps == 640)
    #expect(result.uploadMbps == 42)
    #expect(result.idleRTTMs == 31.5)
    #expect(result.date == date)
}

@Test func interfaceDeltaTrackerHandlesNewAndResetCountersWithoutSpikes() throws {
    var tracker = NetworkInterfaceDeltaTracker()
    #expect(tracker.accept([counter("en1", 1_000, 500)], at: 10) == nil)

    let measuredRate = tracker.accept([counter("en1", 3_000, 1_500)], at: 12)
    let rate = try #require(measuredRate)
    #expect(rate.downloadBytesPerSecond == 1_000)
    #expect(rate.uploadBytesPerSecond == 500)

    let measuredReset = tracker.accept([counter("en1", 50, 20)], at: 13)
    let reset = try #require(measuredReset)
    #expect(reset.downloadBytesPerSecond == 0)
    #expect(reset.uploadBytesPerSecond == 0)

    let measuredAdded = tracker.accept(
        [counter("en1", 150, 70), counter("en5", 10_000, 10_000)], at: 14)
    let added = try #require(measuredAdded)
    #expect(added.downloadBytesPerSecond == 100)
    #expect(added.uploadBytesPerSecond == 50)
}

@MainActor
@Test func customNetworkTargetsPersistInSettings() {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "XFinderNetworkSettings-\(UUID().uuidString)"
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    let target = CustomNetworkTarget(name: "Internal", urlString: "https://example.com/health")

    let store = WorkspaceStore(supportDirectory: directory)
    store.settings.networkDiagnostics.customTargets = [target]

    let relaunched = WorkspaceStore(supportDirectory: directory)
    #expect(relaunched.settings.networkDiagnostics.customTargets == [target])
}

private func counter(_ name: String, _ received: UInt64, _ sent: UInt64) -> NetworkInterfaceCounter {
    NetworkInterfaceCounter(name: name, receivedBytes: received, sentBytes: sent)
}
