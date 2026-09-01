import Foundation

@testable import AteKit

/// Collects the analytics events a model emits, so the funnel is asserted like any other behaviour
/// rather than eyeballed in a dashboard three weeks later.
final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [AnalyticsEvent] = []

    var recorder: AnalyticsRecorder {
        { [weak self] event in
            guard let self else { return }
            lock.withLock { events.append(event) }
        }
    }

    var all: [AnalyticsEvent] { lock.withLock { events } }
    var names: [String] { all.map(\.name) }

    func events(named name: String) -> [AnalyticsEvent] { all.filter { $0.name == name } }
    func first(named name: String) -> AnalyticsEvent? { events(named: name).first }
}
