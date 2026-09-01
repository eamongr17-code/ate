import Foundation

/// One analytics signal: a name and flat string parameters, exactly TelemetryDeck's shape.
///
/// Events are *constructed* in AteKit (so their names and parameters are covered by tests and can
/// never drift silently) and *sent* by the app target, which owns the TelemetryDeck dependency.
public struct AnalyticsEvent: Sendable, Hashable {
    public let name: String
    public let parameters: [String: String]

    public init(name: String, parameters: [String: String] = [:]) {
        self.name = name
        self.parameters = parameters
    }
}

/// The sink. `AnalyticsEvent -> Void`, injectable so tests and previews record instead of send.
public typealias AnalyticsRecorder = @Sendable (AnalyticsEvent) -> Void

/// Where the user came from. Funnel questions are almost always "which entry point produced this",
/// so `source` is a closed set, not a free string.
public enum DetailSource: String, Sendable, CaseIterable, Codable {
    case feed
    case search
    case diary
    case receipt
    /// A deep link, a preview, or a caller that hasn't been wired yet.
    case unknown
}

/// Which screen a "log" call to action was tapped on.
public enum LogCTAOrigin: String, Sendable, CaseIterable, Codable {
    case dishDetail = "dish_detail"
    case restaurantDetail = "restaurant_detail"
}

/// The detail screens' contribution to the funnel. `log_cta_tapped` is the join between browsing
/// and `log_started` — it fires whether or not the log flow is wired yet, so the drop-off between
/// intent and the sheet is measurable from the day the sheet lands.
public enum DetailEvents {
    public static func dishDetailViewed(dishID: UUID, source: DetailSource) -> AnalyticsEvent {
        AnalyticsEvent(
            name: "dish_detail_viewed",
            parameters: ["dish_id": identifier(dishID), "source": source.rawValue]
        )
    }

    public static func restaurantDetailViewed(restaurantID: UUID, source: DetailSource) -> AnalyticsEvent {
        AnalyticsEvent(
            name: "restaurant_detail_viewed",
            parameters: ["restaurant_id": identifier(restaurantID), "source": source.rawValue]
        )
    }

    public static func logCTATapped(from origin: LogCTAOrigin) -> AnalyticsEvent {
        AnalyticsEvent(name: "log_cta_tapped", parameters: ["from": origin.rawValue])
    }

    /// Lowercased, matching how Postgres serialises a uuid — so an event id can be pasted straight
    /// into a query.
    private static func identifier(_ id: UUID) -> String { id.uuidString.lowercased() }
}
