import Foundation

/// Current app version from the bundle's Info.plist (written by
/// build-app.sh from git describe), surfaced in Settings → About.
enum AppVersionInfo {
    static var marketing: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    }

    static var build: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
    }
}

/// Pure version/release parsing, separated from the network call so it stays
/// unit-testable.
enum ReleaseInfoParsing {
    struct Release: Equatable, Sendable {
        let tag: String
        let url: URL?
    }

    /// Numeric version components of a tag or describe string:
    /// "v0.6.2" → [0, 6, 2]; "0.6.2-3-gabc123-dirty" → [0, 6, 2].
    static func components(of version: String) -> [Int] {
        var text = version
        if text.hasPrefix("v") || text.hasPrefix("V") { text.removeFirst() }
        // git describe suffixes ("-3-gabc", "-dirty") are not part of the version.
        if let dash = text.firstIndex(of: "-") { text = String(text[..<dash]) }
        return text.split(separator: ".").map { Int($0) ?? 0 }
    }

    /// True when `remote` names a strictly newer release than `local`
    /// (component-wise, missing components count as 0).
    static func isNewer(remote: String, than local: String) -> Bool {
        let remoteComponents = components(of: remote)
        let localComponents = components(of: local)
        for index in 0..<max(remoteComponents.count, localComponents.count) {
            let remoteValue = index < remoteComponents.count ? remoteComponents[index] : 0
            let localValue = index < localComponents.count ? localComponents[index] : 0
            if remoteValue != localValue { return remoteValue > localValue }
        }
        return false
    }

    /// Parses the GitHub "latest release" API response.
    static func latestRelease(fromData data: Data) -> Release? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let tag = object["tag_name"] as? String,
            !tag.isEmpty
        else { return nil }
        let url = (object["html_url"] as? String).flatMap(URL.init(string:))
        return Release(tag: tag, url: url)
    }
}

/// User-initiated update check against the GitHub releases API — only runs
/// when the user clicks "Check for Updates" in Settings; nothing polls.
enum UpdateChecker {
    static func fetchLatestRelease() async throws -> ReleaseInfoParsing.Release {
        let requestURL = URL(string: "https://api.github.com/repos/tangsanxiao/XFinder/releases/latest")!
        var request = URLRequest(url: requestURL, timeoutInterval: 10)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
            let release = ReleaseInfoParsing.latestRelease(fromData: data)
        else {
            throw UpdateCheckError.unavailable
        }
        return release
    }

    enum UpdateCheckError: Error {
        case unavailable
    }
}
