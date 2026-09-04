import Darwin
import Foundation

struct NetworkInterfaceCounter: Equatable, Sendable {
    let name: String
    let receivedBytes: UInt64
    let sentBytes: UInt64
}

enum NetworkMonotonicClock {
    static func now() -> TimeInterval {
        TimeInterval(clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)) / 1_000_000_000
    }
}

struct NetworkInterfaceDeltaTracker {
    private var previous: [String: (received: UInt64, sent: UInt64)] = [:]
    private var previousTime: TimeInterval?

    mutating func accept(_ counters: [NetworkInterfaceCounter], at time: TimeInterval) -> NetworkTrafficRate? {
        guard !counters.isEmpty else { return nil }
        defer {
            previous = Dictionary(uniqueKeysWithValues: counters.map { ($0.name, ($0.receivedBytes, $0.sentBytes)) })
            previousTime = time
        }
        guard let previousTime, time > previousTime else { return nil }

        var receivedDelta: UInt64 = 0
        var sentDelta: UInt64 = 0
        for counter in counters {
            guard let baseline = previous[counter.name],
                counter.receivedBytes >= baseline.received,
                counter.sentBytes >= baseline.sent
            else { continue }
            receivedDelta += counter.receivedBytes - baseline.received
            sentDelta += counter.sentBytes - baseline.sent
        }
        let elapsed = time - previousTime
        return NetworkTrafficRate(
            timestamp: Date(),
            downloadBytesPerSecond: Double(receivedDelta) / elapsed,
            uploadBytesPerSecond: Double(sentDelta) / elapsed
        )
    }
}

enum NetworkInterfaceCounterReader {
    private static let excludedPrefixes = ["awdl", "llw", "ap", "bridge", "bond", "vmenet", "anpi", "XHC"]

    static func read() -> [NetworkInterfaceCounter] {
        var managementInformationBase: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var requiredBytes = 0
        guard sysctl(&managementInformationBase, 6, nil, &requiredBytes, nil, 0) == 0, requiredBytes > 0 else {
            return []
        }

        for _ in 0..<3 {
            var actualBytes = requiredBytes
            var bytes = [UInt8](repeating: 0, count: actualBytes)
            if sysctl(&managementInformationBase, 6, &bytes, &actualBytes, nil, 0) == 0 {
                return parse(bytes, length: actualBytes)
            }
            guard errno == ENOMEM,
                sysctl(&managementInformationBase, 6, nil, &requiredBytes, nil, 0) == 0
            else { return [] }
        }
        return []
    }

    private static func parse(_ bytes: [UInt8], length: Int) -> [NetworkInterfaceCounter] {
        bytes.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return [] }
            var result: [NetworkInterfaceCounter] = []
            var offset = 0
            while offset + MemoryLayout<if_msghdr>.size <= length {
                let address = baseAddress.advanced(by: offset)
                let header = address.assumingMemoryBound(to: if_msghdr.self).pointee
                let messageLength = Int(header.ifm_msglen)
                guard messageLength > 0, offset + messageLength <= length else { break }
                defer { offset += messageLength }
                guard Int32(header.ifm_type) == RTM_IFINFO2,
                    messageLength >= MemoryLayout<if_msghdr2>.size
                else { continue }

                let detailed = address.assumingMemoryBound(to: if_msghdr2.self).pointee
                guard detailed.ifm_flags & IFF_UP != 0,
                    detailed.ifm_flags & IFF_RUNNING != 0,
                    Int32(detailed.ifm_data.ifi_type) == IFT_ETHER,
                    let name = interfaceName(index: detailed.ifm_index),
                    !excludedPrefixes.contains(where: name.hasPrefix)
                else { continue }
                result.append(
                    NetworkInterfaceCounter(
                        name: name,
                        receivedBytes: detailed.ifm_data.ifi_ibytes,
                        sentBytes: detailed.ifm_data.ifi_obytes
                    ))
            }
            return result
        }
    }

    private static func interfaceName(index: UInt16) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(IF_NAMESIZE))
        guard if_indextoname(UInt32(index), &buffer) != nil else { return nil }
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }
}
