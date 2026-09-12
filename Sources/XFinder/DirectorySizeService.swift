import Foundation

/// Recursive on-disk size of a directory's contents (files only, following
/// neither symlinks nor network volumes), shown in each pane's status bar.
/// The walk runs off the main thread and is cancelled as soon as the pane
/// navigates elsewhere or reloads again.
enum DirectorySizeService {
    /// Async entry point; nil when the walk was cancelled. Mirrors the
    /// detached-worker + cancellation-handler pattern used for transcripts.
    static func recursiveAllocatedSize(of url: URL) async -> Int64? {
        let worker = Task.detached(priority: .utility) {
            allocatedSize(of: url) { Task.isCancelled }
        }
        return await withTaskCancellationHandler {
            await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    /// Synchronous worker — `FileManager.DirectoryEnumerator` cannot iterate
    /// across await boundaries, so the whole walk stays in one sync function
    /// that async callers wrap in a task. `shouldStop` is polled periodically;
    /// a stopped walk reports nil instead of a misleading partial sum.
    static func allocatedSize(of url: URL, shouldStop: () -> Bool = { false }) -> Int64? {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .totalFileAllocatedSizeKey]
        // A missing/unreadable root yields an empty enumerator (sum 0), so
        // check the root explicitly to report failure instead of a fake zero.
        guard (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true,
            let enumerator = FileManager.default.enumerator(
                at: url,
                includingPropertiesForKeys: Array(keys),
                options: []
            )
        else { return nil }
        var total: Int64 = 0
        var scanned = 0
        for case let fileURL as URL in enumerator {
            if scanned % 512 == 0, shouldStop() { return nil }
            scanned += 1
            guard let values = try? fileURL.resourceValues(forKeys: keys),
                values.isRegularFile == true
            else { continue }
            total += Int64(values.totalFileAllocatedSize ?? 0)
        }
        return shouldStop() ? nil : total
    }
}
