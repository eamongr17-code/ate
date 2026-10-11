import Foundation

/// **The share extension's notes to the app**, left in the app group's defaults.
///
/// Two things cross: the extension's analytics events, which the app sends with its own TelemetryDeck
/// session the next time it comes forward (an extension is torn down a second after Save, too soon
/// to trust a network flush), and the fact that a dish was saved, so Saved reads its list again.
public struct ShareInbox: Sendable {
    /// Events kept while the app has not come forward; the oldest go first past this.
    static let eventLimit = 200
    static let eventsKey = "share.events"
    static let changedKey = "share.ownSavesChanged"

    private let suiteName: String

    public init(suiteName: String = AteAppGroup.identifier) {
        self.suiteName = suiteName
    }

    /// `nil` only when the app group is missing from the build's entitlements.
    private var defaults: UserDefaults? { UserDefaults(suiteName: suiteName) }

    // MARK: - From the extension

    /// Leaves an event for the app to send.
    public func post(_ event: AnalyticsEvent) {
        guard let defaults else { return }
        var queued = defaults.array(forKey: Self.eventsKey) as? [[String: Any]] ?? []
        queued.append(["name": event.name, "parameters": event.parameters])
        if queued.count > Self.eventLimit { queued.removeFirst(queued.count - Self.eventLimit) }
        defaults.set(queued, forKey: Self.eventsKey)
    }

    /// A dish was saved to Saved from the share sheet.
    public func markOwnSavesChanged() {
        defaults?.set(true, forKey: Self.changedKey)
    }

    // MARK: - In the app

    /// Every event left since the last call, oldest first, and the queue emptied.
    public func takeEvents() -> [AnalyticsEvent] {
        guard let defaults, let queued = defaults.array(forKey: Self.eventsKey) as? [[String: Any]] else {
            return []
        }
        defaults.removeObject(forKey: Self.eventsKey)
        return queued.compactMap { entry in
            guard let name = entry["name"] as? String else { return nil }
            return AnalyticsEvent(name: name, parameters: entry["parameters"] as? [String: String] ?? [:])
        }
    }

    /// Whether a dish was saved from the share sheet since the last call — and the note cleared.
    public func takeOwnSavesChanged() -> Bool {
        guard let defaults, defaults.bool(forKey: Self.changedKey) else { return false }
        defaults.removeObject(forKey: Self.changedKey)
        return true
    }
}
