import Foundation

/// What a ``SearchPicker`` is searching. One component, three subjects (§10) — the third,
/// ``allDishes``, is the Search tab's global "Dishes" scope, which has no restaurant context and so
/// offers no create-fallback.
public enum SearchSubject: Sendable, Hashable {
    case restaurants
    /// Dishes within one restaurant — the WHAT step, and the only subject that can create a dish.
    case dishes(restaurantID: UUID, restaurantName: String)
    /// Every dish, everywhere. Search tab only.
    case allDishes

    /// For telemetry (`search_query(subject:)` etc.).
    public var telemetryName: String {
        switch self {
        case .restaurants: "restaurants"
        case .dishes: "dishes"
        case .allDishes: "all_dishes"
        }
    }

    public var restaurantID: UUID? {
        if case .dishes(let restaurantID, _) = self { return restaurantID }
        return nil
    }

    public var restaurantName: String? {
        if case .dishes(_, let name) = self { return name }
        return nil
    }
}

/// Debounce, minimum length, and normalisation — the three knobs that decide when a keystroke costs
/// a request. Pure, so the thresholds are asserted in tests rather than buried in a view.
///
/// Cost note (places-integration.md): every restaurant keystroke past the gate is a billable Google
/// autocomplete call, session-token-batched. 250 ms + 2 chars is the FE-PLACES-2 lever.
public struct SearchQueryPolicy: Sendable, Hashable {
    public static let debounce: Duration = .milliseconds(250)

    public let minimumLength: Int

    public init(minimumLength: Int) {
        self.minimumLength = minimumLength
    }

    public init(subject: SearchSubject) {
        switch subject {
        case .restaurants:
            // §11.1: 1 char changes nothing and fires no request.
            self.init(minimumLength: 2)
        case .dishes:
            // §11.3: filtering starts at 1 char — the catalogue is one restaurant's, so it's cheap.
            self.init(minimumLength: 1)
        case .allDishes:
            // Global catalogue: 2 chars, same reasoning as restaurants (a 1-char `%a%` is a scan).
            self.init(minimumLength: 2)
        }
    }

    /// Trimmed; internal whitespace left alone (the server matchers handle it).
    public func normalize(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Whether this keystroke should fire a request. Below the threshold the picker keeps showing
    /// its default sections — it must never flash to empty (§11.5).
    public func shouldSearch(_ raw: String) -> Bool {
        normalize(raw).count >= minimumLength
    }

    /// The query to send, or nil when the default sections stand.
    public func query(from raw: String) -> String? {
        let normalized = normalize(raw)
        return normalized.count >= minimumLength ? normalized : nil
    }
}
