import Foundation

/// System volume capacity snapshot shown in Settings → Storage. Read once
/// when the settings panel opens (a single resource-values syscall, no
/// polling).
struct DiskCapacity: Equatable, Sendable {
    var volumeName: String
    var totalBytes: Int64
    /// "Available for important usage" (includes purgeable data) — the same
    /// available figure Finder shows.
    var availableBytes: Int64

    var usedBytes: Int64 { max(0, totalBytes - availableBytes) }

    var usedFraction: Double {
        guard totalBytes > 0 else { return 0 }
        return min(1, max(0, Double(usedBytes) / Double(totalBytes)))
    }
}

enum DiskCapacityProbe {
    /// Capacity of the boot volume; `root` is injectable for tests.
    static func systemVolume(root: URL = URL(fileURLWithPath: "/")) -> DiskCapacity? {
        let keys: Set<URLResourceKey> = [
            .volumeNameKey,
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
        ]
        guard let values = try? root.resourceValues(forKeys: keys),
            let total = values.volumeTotalCapacity,
            let available = values.volumeAvailableCapacityForImportantUsage
        else { return nil }
        return DiskCapacity(
            volumeName: values.volumeName ?? "Macintosh HD",
            totalBytes: Int64(total),
            availableBytes: available
        )
    }
}
