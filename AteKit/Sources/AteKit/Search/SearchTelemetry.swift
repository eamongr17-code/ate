import Foundation

/// The picker's funnel events (spec §11.6) plus the create-fallback counter the brief adds.
///
/// Defined here, in AteKit, rather than as `TelemetryDeck.signal("…")` calls scattered through
/// views: the event *names and parameters are a contract* with growth-lead's dashboards, so they get
/// to be plain values a test can assert. The App target owns the only thing that isn't testable —
/// actually handing them to TelemetryDeck (see `TelemetryDeckSink`).
public enum SearchEvent: Sendable, Hashable {
    /// Fired once per picker session, on appear.
    case opened(context: SearchContextName, subject: SearchSubject)
    /// Fired per completed (debounced, non-stale) query.
    case query(subject: SearchSubject, length: Int, resultCount: Int, milliseconds: Int)
    /// Fired on a successful selection. `index` is the row's position in the rendered list.
    case resultSelected(subject: SearchSubject, kind: String, index: Int)
    /// **Redefined (journal-first §6).** The add row is now permanently visible, so "it appeared" is
    /// no longer a signal. This fires on the *transition into the direct-create state* — the query
    /// has no exact match, so one tap would create and select — once per distinct query.
    ///
    /// Series break: the name changed from `search_create_shown` to `create_shown` at the same time,
    /// so the old series can't be silently concatenated onto a differently-defined new one.
    case createShown(subject: SearchSubject)
    /// Fired when the create-fallback row is tapped.
    case createUsed(subject: SearchSubject)
    /// **New (§6).** The standing add row was tapped, whatever state it was in — the denominator
    /// `create_used` never had. `mode` says whether the tap created directly or opened a sheet.
    case createRowTapped(subject: SearchSubject, hadQuery: Bool, mode: CreateRowMode)
    /// Fired when a query ≥ the minimum length returns nothing.
    case zeroResults(subject: SearchSubject, queryLength: Int)
    /// Brief addendum: a dish was actually created from the picker's fallback.
    case dishCreateFallbackUsed(restaurantID: UUID)

    public var name: String {
        switch self {
        case .opened: "search_opened"
        case .query: "search_query"
        case .resultSelected: "search_result_selected"
        case .createShown: "create_shown"
        case .createUsed: "search_create_used"
        case .createRowTapped: "create_row_tapped"
        case .zeroResults: "search_zero_results"
        case .dishCreateFallbackUsed: "dish_create_fallback_used"
        }
    }

    /// TelemetryDeck takes `[String: String]`; numbers are stringified at the edge so the shape of
    /// a signal is fully determined here.
    public var parameters: [String: String] {
        switch self {
        case .opened(let context, let subject):
            ["context": context.rawValue, "subject": subject.telemetryName]
        case .query(let subject, let length, let resultCount, let milliseconds):
            [
                "subject": subject.telemetryName,
                "length": String(length),
                "result_count": String(resultCount),
                "ms": String(milliseconds)
            ]
        case .resultSelected(let subject, let kind, let index):
            ["subject": subject.telemetryName, "kind": kind, "index": String(index)]
        case .createShown(let subject), .createUsed(let subject):
            ["subject": subject.telemetryName]
        case .createRowTapped(let subject, let hadQuery, let mode):
            [
                "subject": subject.telemetryName,
                "had_query": hadQuery ? "true" : "false",
                "mode": mode.rawValue
            ]
        case .zeroResults(let subject, let queryLength):
            ["subject": subject.telemetryName, "query_length": String(queryLength)]
        case .dishCreateFallbackUsed(let restaurantID):
            ["restaurant_id": restaurantID.uuidString]
        }
    }
}

/// What the standing add row did when it was tapped (§6): resolved in place, or opened a form.
public enum CreateRowMode: String, Sendable, Hashable, CaseIterable {
    /// Non-empty query, no exact match: creates and selects with zero extra taps.
    case direct
    /// Empty query, or an exact match that has to be renamed — a minimal Add sheet.
    case sheet
}

/// `.browse` / `.pick` as it appears on the wire. The view's `SearchContext` carries a closure and
/// therefore can't be `Equatable`/`Sendable`-cheap; this is its name.
public enum SearchContextName: String, Sendable, Hashable {
    case browse
    case pick
}

/// Where events go. One method, so a test double is three lines and the App's TelemetryDeck
/// adapter is four.
public protocol SearchTelemetrySink: Sendable {
    func send(_ event: SearchEvent)
}

/// Drops everything — the default for previews and tests that aren't about telemetry.
public struct NoOpSearchTelemetrySink: SearchTelemetrySink {
    public init() {}
    public func send(_ event: SearchEvent) {}
}
