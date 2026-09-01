import Foundation

/// How the log sheet was opened (§1.1).
public enum LogEntryKind: String, Sendable, Hashable, Codable {
    case tab
    case restaurant
    case dish
    case resume
}

/// How the restaurant got resolved (§8). Derived from the row the picker actually resolved, not
/// guessed from the query — see `LoggingRestaurantSearch`.
public enum LogWhereSource: String, Sendable, Hashable {
    case nearby
    case recent
    case searchPlace = "search_place"
    case searchManual = "search_manual"
    case addedManual = "added_manual"
}

/// How the dish got resolved (§8).
public enum LogWhatSource: String, Sendable, Hashable {
    case history
    case menu
    case newDish = "new_dish"
}

/// How a score was set — the two gestures and VoiceOver (§2.3, §2.5).
public enum LogRatingMethod: String, Sendable, Hashable {
    case drag
    case tap
    case accessibility = "a11y"
}

/// Which of the §2.6 A/B placements is live. Ships as a property on every `log_rating_set` so the
/// on-device decision is made on data, not on argument.
public enum RatingPlacementVariant: String, Sendable, Hashable, Codable, CaseIterable, Identifiable {
    /// Default: the rating lives on the dish card.
    case inlineOnCard = "inline_on_card"
    /// Selecting a dish presents a focused rating step; the canvas is reached already-rated.
    case rateOnSelect = "rate_on_select"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .inlineOnCard: "A — rate on the card"
        case .rateOnSelect: "B — rate on select"
        }
    }
}

/// Which screen the sitting was abandoned from (§8 `log_abandoned(step:)`).
public enum LogStep: String, Sendable, Hashable {
    case whereStep = "where"
    case what
    case canvas
    case receipt
}

/// **The log funnel** (§8) — the product's core loop, instrumented end to end.
///
/// `log_posted(seconds_from_open)` is the friction north-star: the 30-second budget (§1.2) is a claim
/// about this number, and it is the one property that must never be dropped.
///
/// Values, not `TelemetryDeck.signal` calls, for the same reason as ``SearchEvent``: the names and
/// parameters are a contract with growth-lead's dashboards, so they get to be asserted in tests.
public enum LogEvent: Sendable, Hashable {
    case opened(entry: LogEntryKind)
    case whereResolved(source: LogWhereSource, millisecondsFromOpen: Int)
    case whatResolved(source: LogWhatSource, dishIndex: Int)
    case ratingSet(value: Double, method: LogRatingMethod, variant: RatingPlacementVariant)
    case dishAdded(dishIndex: Int)
    case dishRemoved(dishIndex: Int)
    case posted(dishCount: Int, hasNote: Bool, hasPhoto: Bool, secondsFromOpen: Int)
    case postFailed(reason: String, dishCount: Int, attempt: Int)
    case abandoned(step: LogStep, dishCount: Int, savedDraft: Bool)
    case draftResumed(ageMinutes: Int)
    case receiptShown(dishCount: Int)
    case receiptShared(dishCount: Int, activityType: String)

    public var name: String {
        switch self {
        case .opened: "log_opened"
        case .whereResolved: "log_where_resolved"
        case .whatResolved: "log_what_resolved"
        case .ratingSet: "log_rating_set"
        case .dishAdded: "log_dish_added"
        case .dishRemoved: "log_dish_removed"
        case .posted: "log_posted"
        case .postFailed: "log_post_failed"
        case .abandoned: "log_abandoned"
        case .draftResumed: "log_draft_resumed"
        case .receiptShown: "receipt_shown"
        case .receiptShared: "receipt_shared"
        }
    }

    /// TelemetryDeck takes `[String: String]`; numbers are stringified here so the whole shape of a
    /// signal is decided in one testable place.
    public var parameters: [String: String] {
        switch self {
        case .opened(let entry):
            ["entry": entry.rawValue]
        case .whereResolved(let source, let milliseconds):
            ["source": source.rawValue, "ms_from_open": String(milliseconds)]
        case .whatResolved(let source, let dishIndex):
            ["source": source.rawValue, "dish_index": String(dishIndex)]
        case .ratingSet(let value, let method, let variant):
            [
                "value": Self.number(value),
                "method": method.rawValue,
                "variant": variant.rawValue
            ]
        case .dishAdded(let dishIndex), .dishRemoved(let dishIndex):
            ["dish_index": String(dishIndex)]
        case .posted(let dishCount, let hasNote, let hasPhoto, let secondsFromOpen):
            [
                "dish_count": String(dishCount),
                "has_note": String(hasNote),
                "has_photo": String(hasPhoto),
                "seconds_from_open": String(secondsFromOpen)
            ]
        case .postFailed(let reason, let dishCount, let attempt):
            ["reason": reason, "dish_count": String(dishCount), "attempt": String(attempt)]
        case .abandoned(let step, let dishCount, let savedDraft):
            [
                "step": step.rawValue,
                "dish_count": String(dishCount),
                "saved_draft": String(savedDraft)
            ]
        case .draftResumed(let ageMinutes):
            ["age_minutes": String(ageMinutes)]
        case .receiptShown(let dishCount):
            ["dish_count": String(dishCount)]
        case .receiptShared(let dishCount, let activityType):
            ["dish_count": String(dishCount), "activity_type": activityType]
        }
    }

    /// `4.5`, never `4.500000` and never locale-decimal-comma — a dashboard groups on the string.
    private static func number(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value)
    }
}

/// Where log events go.
public protocol LogTelemetrySink: Sendable {
    func send(_ event: LogEvent)
}

public struct NoOpLogTelemetrySink: LogTelemetrySink {
    public init() {}
    public func send(_ event: LogEvent) {}
}

/// The reason string on `log_post_failed`. A short closed set — a raw PostgREST body would make the
/// property uncountable, and it belongs in Sentry, which already has it.
public enum LogPostFailureReason {
    public static func of(_ error: any Error) -> String {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .dataNotAllowed: return "offline"
            case .timedOut: return "timeout"
            default: return "network"
            }
        }
        if (error as? AteAPIError) == .notAuthenticated { return "auth" }
        return "server"
    }
}
