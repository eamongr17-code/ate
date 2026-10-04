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
    /// An entry page — its bill lines, and the place at its head.
    case entry
    /// The Saved shelf: a place head, or a saved dish row.
    case saved
    /// Somebody's profile, from one of its slips.
    case profile
    /// Home. Named for the tab, because `diary` is what this surface used to be called and an event
    /// parameter that disagrees with the app's own word for a screen is a trap for whoever reads it.
    case journal
    /// The place page — a "what to order" row.
    case place
    /// The dish page — its place line.
    case dish
    /// A link into the app — a shared entry (`ate://entry/<id>`).
    case link
    /// A dish page's "More like this" carousel (round 7).
    case similar
    /// A tag's page — the list a dish page's "More to explore" chip opens (round 7).
    case tag
    /// An entry page's "More at" or "More like this" shelf (build 87).
    case entryMore = "entry_more"
}

/// Which affordance a "log" call to action was tapped on.
///
/// Every entry point into the Log sheet has a value here, because the question this answers is
/// "where does logging actually start" — and an unlabelled entry point silently reads as zero.
public enum LogCTAOrigin: String, Sendable, CaseIterable, Codable {
    /// The composer row at the top of the diary.
    case diaryComposer = "diary_composer"
    /// The "Continue at …" resume row above the composer.
    case diaryResume = "diary_resume"
    /// The composer on the first-run (empty) diary — the same button, but the first one ever tapped.
    case diaryEmpty = "diary_empty"
    /// The `+` in the tab bar.
    case tabBar = "tab_bar"
    /// "Log this again" on your own journal entry.
    case entryLogAgain = "entry_log_again"
    case dishDetail = "dish_detail"
    case restaurantDetail = "restaurant_detail"
}

/// Where a dish page's review row sent the reader.
public enum DishReviewTarget: String, Sendable {
    case entry
    case profile
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

    /// A review row on a dish page was opened (round 4): the row opens the visit, the avatar and
    /// handle open the person. `target` is `entry` or `profile`.
    public static func dishReviewOpened(target: DishReviewTarget) -> AnalyticsEvent {
        AnalyticsEvent(name: "dish_review_opened", parameters: ["target": target.rawValue])
    }

    /// A dish's photo on a place's menu opened the photo viewer (round 4).
    public static func menuPhotoOpened() -> AnalyticsEvent {
        AnalyticsEvent(name: "menu_photo_opened", parameters: [:])
    }

    /// A "More to explore" chip on a dish page was tapped (round 7): which kind of tag — style,
    /// cuisine, suburb, city or diet — is what people explore by.
    public static func dishTagOpened(kind: DishTag.Kind) -> AnalyticsEvent {
        AnalyticsEvent(name: "dish_tag_opened", parameters: ["kind": kind.rawValue])
    }

    /// A "More like this" card on a dish page was tapped (round 7). `position` is 1-based: how far
    /// along the carousel people go before one earns a tap.
    public static func similarDishOpened(position: Int) -> AnalyticsEvent {
        AnalyticsEvent(name: "similar_dish_opened", parameters: ["position": String(position)])
    }

    /// A card on an entry page's "More at <place>" or "More like this" shelf was tapped (build 87).
    /// `position` is 1-based, as `similar_dish_opened`'s.
    public static func entryMoreOpened(section: EntryMoreStore.Section, position: Int) -> AnalyticsEvent {
        AnalyticsEvent(name: "entry_more_opened", parameters: [
            "section": section.rawValue, "position": String(position)
        ])
    }

    /// A tag's page of dishes was shown (round 7).
    public static func tagDishesViewed(kind: DishTag.Kind) -> AnalyticsEvent {
        AnalyticsEvent(name: "tag_dishes_viewed", parameters: ["kind": kind.rawValue])
    }

    public static func logCTATapped(from origin: LogCTAOrigin) -> AnalyticsEvent {
        AnalyticsEvent(name: "log_cta_tapped", parameters: ["from": origin.rawValue])
    }

    /// Lowercased, matching how Postgres serialises a uuid — so an event id can be pasted straight
    /// into a query.
    private static func identifier(_ id: UUID) -> String { id.uuidString.lowercased() }
}
