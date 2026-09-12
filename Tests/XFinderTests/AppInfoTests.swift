import Foundation
import Testing

@testable import XFinder

// MARK: - Changelog parsing

@Test func changelogParserMapsHeadingsAndBullets() {
    let markdown = """
        # Changelog

        ## [Unreleased]

        ### Added
        - Feature one
          - Nested detail
        Plain note
        """
    let lines = ChangelogParser.parse(markdown)

    #expect(
        lines.map(\.kind) == [
            .heading1, .heading2, .heading3, .bullet(indent: 0), .bullet(indent: 1), .text,
        ])
    #expect(lines[0].content == "Changelog")
    #expect(lines[3].content == "Feature one")
    #expect(lines[4].content == "Nested detail")
}

@Test func changelogParserSkipsBlankLines() {
    #expect(ChangelogParser.parse("\n\n  \n").isEmpty)
}

// MARK: - Event log

@MainActor
@Test func storeRecordsStatusAndErrorsNewestFirst() {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("XFinderEvents-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = WorkspaceStore(supportDirectory: dir)
    store.clearEvents()  // drop init-time noise

    store.statusMessage = "Did a thing"
    store.lastError = "Something failed"
    store.lastError = nil  // alert dismissal — must NOT log

    #expect(store.events.count == 2)
    #expect(store.events[0].isError)
    #expect(store.events[0].message == "Something failed")
    #expect(store.events[1].message == "Did a thing")

    store.clearEvents()
    #expect(store.events.isEmpty)
}

@MainActor
@Test func focusChangesAreTracedIntoTheEventLog() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("XFinderEvents-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = WorkspaceStore(supportDirectory: dir)
    store.createWorkspace()
    let paneID = try #require(store.openInNewPane(URL(fileURLWithPath: "/tmp"), title: "tmp"))
    store.clearEvents()

    store.focusedPaneID = nil
    store.focusedPaneID = paneID  // back to the pane
    store.focusedPaneID = paneID  // no-op — must not log twice

    let focusEvents = store.events.filter { $0.message.hasPrefix("Focus → ") }
    #expect(focusEvents.count == 2)
}

@MainActor
@Test func settingsPersistAcrossStoreInstances() {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("XFinderSettings-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }

    let store = WorkspaceStore(supportDirectory: dir)
    #expect(store.settings.claudeIntegrationEnabled == false)  // off by default
    store.settings.claudeIntegrationEnabled = true
    store.settings.claudeCLIPath = "/opt/homebrew/bin/claude"
    store.settings.agentCenterSection = .sessions

    let relaunched = WorkspaceStore(supportDirectory: dir)
    #expect(relaunched.settings.claudeIntegrationEnabled)
    #expect(relaunched.settings.claudeCLIPath == "/opt/homebrew/bin/claude")
    #expect(relaunched.settings.agentCenterSection == .sessions)
}

@Test func legacySettingsDecodeWithDoubaoDisabled() throws {
    let data = Data(
        """
        {
          "claudeIntegrationEnabled": true,
          "language": "english"
        }
        """.utf8
    )

    let settings = try JSONDecoder().decode(AppSettings.self, from: data)

    #expect(settings.claudeIntegrationEnabled)
    #expect(settings.language == .english)
    #expect(settings.agentCenterSection == .inbox)
    #expect(!settings.doubaoTTS.enabled)
    #expect(settings.doubaoTTS.resourceID == "seed-tts-2.0")
}

@Test func cliCommandQuotesCustomPathAndFallsBackToPath() {
    #expect(ClaudeBridge.cliCommand(path: "") == "claude")
    #expect(ClaudeBridge.cliCommand(path: "  ") == "claude")
    #expect(ClaudeBridge.cliCommand(path: "/opt/homebrew/bin/claude") == "'/opt/homebrew/bin/claude'")
}

@MainActor
@Test func eventLogIsCappedAt200() {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("XFinderEvents-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = WorkspaceStore(supportDirectory: dir)

    for index in 0..<250 {
        store.statusMessage = "event \(index)"
    }

    #expect(store.events.count == 200)
    #expect(store.events.first?.message == "event 249")
}

// MARK: - Release version parsing

@Test func versionComponentsStripPrefixAndDescribeSuffix() {
    #expect(ReleaseInfoParsing.components(of: "v0.6.2") == [0, 6, 2])
    #expect(ReleaseInfoParsing.components(of: "0.6.2-3-gabc123-dirty") == [0, 6, 2])
    #expect(ReleaseInfoParsing.components(of: "1.2") == [1, 2])
}

@Test func isNewerComparesComponentWise() {
    #expect(ReleaseInfoParsing.isNewer(remote: "v0.7.0", than: "0.6.2"))
    #expect(!ReleaseInfoParsing.isNewer(remote: "v0.6.2", than: "0.6.2"))
    #expect(!ReleaseInfoParsing.isNewer(remote: "v0.6.1", than: "0.6.2"))
    // A local dev build just past the latest tag is not "outdated".
    #expect(!ReleaseInfoParsing.isNewer(remote: "v0.6.2", than: "0.6.2-3-gabc123"))
    #expect(ReleaseInfoParsing.isNewer(remote: "v0.6.10", than: "0.6.2"))
}

@Test func latestReleaseParsesGitHubResponse() {
    let json = #"{"tag_name": "v0.7.0", "html_url": "https://github.com/tangsanxiao/XFinder/releases/tag/v0.7.0"}"#
    let release = ReleaseInfoParsing.latestRelease(fromData: Data(json.utf8))
    #expect(release?.tag == "v0.7.0")
    #expect(release?.url?.absoluteString == "https://github.com/tangsanxiao/XFinder/releases/tag/v0.7.0")
    #expect(ReleaseInfoParsing.latestRelease(fromData: Data("{}".utf8)) == nil)
    #expect(ReleaseInfoParsing.latestRelease(fromData: Data("not json".utf8)) == nil)
}

// MARK: - Disk capacity

@Test func diskCapacityComputesUsedAndFraction() {
    let disk = DiskCapacity(volumeName: "Macintosh HD", totalBytes: 500, availableBytes: 200)
    #expect(disk.usedBytes == 300)
    #expect(disk.usedFraction == 0.6)
}

@Test func diskCapacityClampsDegenerateValues() {
    let zero = DiskCapacity(volumeName: "v", totalBytes: 0, availableBytes: 0)
    #expect(zero.usedFraction == 0)
    // Available beyond total (over-reported purgeable) never yields negatives.
    let over = DiskCapacity(volumeName: "v", totalBytes: 100, availableBytes: 150)
    #expect(over.usedBytes == 0)
    #expect(over.usedFraction == 0)
}

@Test func diskCapacityProbeReadsSystemVolume() {
    let disk = DiskCapacityProbe.systemVolume()
    #expect(disk != nil)
    #expect((disk?.totalBytes ?? 0) > 0)
    #expect((disk?.availableBytes ?? -1) >= 0)
    #expect(disk?.volumeName.isEmpty == false)
}
