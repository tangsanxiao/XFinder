import Foundation
import Network

final class NetworkPathObserver: @unchecked Sendable {
    private let lock = NSLock()
    private var monitor: NWPathMonitor?

    func start(handler: @escaping @Sendable (NetworkPathSnapshot) -> Void) {
        stop()
        let nextMonitor = NWPathMonitor()
        nextMonitor.pathUpdateHandler = { path in
            handler(Self.snapshot(path))
        }
        lock.lock()
        monitor = nextMonitor
        lock.unlock()
        nextMonitor.start(queue: DispatchQueue(label: "com.xfinder.network-path", qos: .utility))
    }

    func stop() {
        lock.lock()
        let current = monitor
        monitor = nil
        lock.unlock()
        current?.cancel()
    }

    private static func snapshot(_ path: NWPath) -> NetworkPathSnapshot {
        NetworkPathSnapshot(
            isSatisfied: path.status == .satisfied,
            interfaceNames: path.availableInterfaces.map(\.name).sorted(),
            interfaceTypes: path.availableInterfaces.map { typeName($0.type) }.uniqued().sorted(),
            supportsIPv4: path.supportsIPv4,
            supportsIPv6: path.supportsIPv6,
            supportsDNS: path.supportsDNS,
            isExpensive: path.isExpensive,
            isConstrained: path.isConstrained
        )
    }

    private static func typeName(_ type: NWInterface.InterfaceType) -> String {
        switch type {
        case .wifi: return "Wi-Fi"
        case .wiredEthernet: return "Ethernet"
        case .cellular: return "Cellular"
        case .loopback: return "Loopback"
        case .other: return "Other"
        @unknown default: return "Unknown"
        }
    }
}

private extension Sequence where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
