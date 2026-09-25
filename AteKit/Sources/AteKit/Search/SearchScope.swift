import Foundation

/// **The four segments of the Search tab** (`Search.dc.html`): Places · Dishes · People · Saved.
///
/// Not ``SearchSubject``, deliberately. That one names what the *picker* inside the composer is
/// choosing (a restaurant for this entry, a dish at this restaurant), and it exists to decide what a
/// pick does. This names what the Search *tab* is looking through, which is a different question:
/// two of these scopes (people, your own shelf) are not things the composer can ever pick, and one
/// of them (places) is backed by the very same component the composer's Place key uses.
public enum SearchScope: String, Sendable, Hashable, CaseIterable, Identifiable, Codable {
    case places
    case dishes
    case people
    /// Your own shelf, searched. A save is per dish, so the rows here are dishes with their bookmark.
    case saved

    public var id: String { rawValue }

    /// The pill's label, as the artboard sets it.
    public var title: String {
        switch self {
        case .places: "Places"
        case .dishes: "Dishes"
        case .people: "People"
        case .saved: "Saved"
        }
    }

    /// `scope` on `search_performed` / `search_result_opened`.
    public var telemetryName: String { rawValue }

    /// How many characters before a keystroke costs a request: two, everywhere. It is the server's
    /// own floor (`search_key` under two characters returns `[]`, 0031), so a shorter query is a
    /// round trip that can only come back empty. Below it, Places and Saved show their standing
    /// lists and Dishes and People show nothing.
    public var minimumQueryLength: Int { 2 }

    /// Whether this scope has something honest to show **before a single character is typed**.
    ///
    /// Places does: `Nearby`, which is the artboard's own zero state — a list *ranked* by where the
    /// phone is, never a place attached to anything (design rule 8). Saved does: your shelf, which
    /// is yours and already on the server. Dishes and People do not, and the design's answer to that
    /// is the field itself — a screen with nothing to say says nothing (design rule 1).
    public var hasStandingList: Bool {
        switch self {
        case .places, .saved: true
        case .dishes, .people: false
        }
    }
}

extension SearchQueryPolicy {
    /// The same debounce and normalisation the picker uses, with the tab's own minimum length.
    public init(scope: SearchScope) {
        self.init(minimumLength: scope.minimumQueryLength)
    }
}
