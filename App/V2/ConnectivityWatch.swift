import Foundation
import Network

/// **The moment the connection comes back** (receipt fallback): one element each time the phone goes
/// from no usable path to a usable one. The outbox is worked then, so an entry saved offline finishes
/// its receipt without the person doing anything.
enum ConnectivityWatch {
    static func restorations() -> AsyncStream<Void> {
        AsyncStream { continuation in
            let monitor = NWPathMonitor()
            let last = LastPath()
            monitor.pathUpdateHandler = { path in
                let isOnline = path.status == .satisfied
                if last.wasOnline == false, isOnline { continuation.yield() }
                last.wasOnline = isOnline
            }
            continuation.onTermination = { _ in monitor.cancel() }
            monitor.start(queue: DispatchQueue(label: "ate.connectivity", qos: .utility))
        }
    }
}

/// The last path's state. Only the monitor's own serial queue touches it.
private final class LastPath: @unchecked Sendable {
    var wasOnline: Bool?
}
