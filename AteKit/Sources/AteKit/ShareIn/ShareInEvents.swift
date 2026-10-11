import Foundation

/// **Share to Ate, counted** — a post shared in from TikTok, Instagram or a page. The save itself is
/// ``OwnSaveEvents/added(source:origin:)`` with origin `share_extension`; these are the steps around
/// it. Built here so the names are pinned by tests; the extension leaves them in the ``ShareInbox``
/// and the app sends them.
public enum ShareInEvents {
    /// What `read-share` gave the card.
    public enum Outcome: String, Sendable, CaseIterable {
        /// A dish, a place, or both, to check.
        case suggested
        /// It read the post and suggested neither.
        case empty
        /// No answer — the fields are filled by hand.
        case failed
    }

    /// Where the suggested place stood.
    public enum PlaceMatch: String, Sendable, CaseIterable {
        /// A place we already hold.
        case local
        /// One Google prediction, turned into a row on the card.
        case google
        /// None — "Find the place". (Not spelled `none`, which reads as `Optional.none`.)
        case unmatched = "none"
    }

    /// The card read the shared link. `reason` only on a failed read.
    public static func read(
        source: OwnSaveSource, outcome: Outcome, dish: Bool, place: PlaceMatch, reason: String? = nil
    ) -> AnalyticsEvent {
        var parameters = [
            "source": source.rawValue,
            "outcome": outcome.rawValue,
            "dish": dish ? "true" : "false",
            "place": place.rawValue
        ]
        if let reason { parameters["reason"] = reason }
        return AnalyticsEvent(name: "share_read", parameters: parameters)
    }

    /// The card rose signed out, and said so.
    public static func signedOut() -> AnalyticsEvent {
        AnalyticsEvent(name: "share_signed_out")
    }

    /// The card was closed without a save. `edited` says the dish or place had been changed.
    public static func dismissed(source: OwnSaveSource, edited: Bool) -> AnalyticsEvent {
        AnalyticsEvent(name: "share_dismissed", parameters: [
            "source": source.rawValue, "edited": edited ? "true" : "false"
        ])
    }
}
