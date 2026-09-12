import Foundation
import Testing

@testable import XFinder

private func makeTempDirectory() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("XFinderDirSize-\(UUID().uuidString)")
}

@Test func allocatedSizeSumsNestedFiles() throws {
    let root = makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let sub = root.appendingPathComponent("sub")
    try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
    // Random bytes defeat transparent compression so allocated ≥ logical size.
    try Data((0..<100_000).map { _ in UInt8.random(in: 0...255) }).write(to: root.appendingPathComponent("a.bin"))
    try Data((0..<50_000).map { _ in UInt8.random(in: 0...255) }).write(to: sub.appendingPathComponent("b.bin"))

    let size = DirectorySizeService.allocatedSize(of: root)
    #expect(size != nil)
    #expect((size ?? 0) >= 150_000)
}

@Test func allocatedSizeCountsSubdirectoryOnlyFiles() throws {
    let root = makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let sub = root.appendingPathComponent("nested/deeper")
    try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
    try Data(repeating: 0xAB, count: 200_000).write(to: sub.appendingPathComponent("c.bin"))

    let size = DirectorySizeService.allocatedSize(of: root)
    #expect((size ?? 0) >= 200_000)
}

@Test func allocatedSizeReturnsNilWhenCancelled() throws {
    let root = makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try Data(repeating: 0x01, count: 1_000).write(to: root.appendingPathComponent("a.bin"))

    #expect(DirectorySizeService.allocatedSize(of: root) { true } == nil)
}

@Test func allocatedSizeHandlesMissingDirectory() {
    let missing = FileManager.default.temporaryDirectory.appendingPathComponent(
        "XFinderDirSize-missing-\(UUID().uuidString)")
    #expect(DirectorySizeService.allocatedSize(of: missing) == nil)
}

@Test func recursiveAllocatedSizeRunsOffCaller() async throws {
    let root = makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try Data(repeating: 0x02, count: 10_000).write(to: root.appendingPathComponent("a.bin"))

    let size = await DirectorySizeService.recursiveAllocatedSize(of: root)
    #expect((size ?? 0) >= 10_000)
}
