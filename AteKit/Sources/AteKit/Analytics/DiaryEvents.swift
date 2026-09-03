import Foundation

/// Where a restaurant name was tapped (Rule R, §5/§9). Every site that renders a restaurant name
/// with an id in hand is here, because the question this answers is "does making restaurants
/// reachable everywhere actually get used, and from where" — and an unlabelled site reads as zero.
public enum RestaurantLinkOrigin: String, Sendable, CaseIterable, Codable {
    /// The place line inside a feed card.
    case feedRow = "feed_row"
    /// The leading name on a diary sitting header.
    case diarySitting = "diary_sitting"
    /// The onward disclosure row on your own journal entry.
    case diaryEntry = "diary_entry"
    /// The restaurant row under the dish detail aggregate.
    case dishDetail = "dish_detail"
    /// The receipt's place line — on screen only; never in the exported image.
    case receipt = "receipt"
}

/// The diary's funnel signals. Built here (so the names and parameters are asserted by tests and can
/// never drift silently) and sent by the app target's ``AnalyticsRecorder``.
///
/// Deliberately few: the question the diary answers for the funnel is "do people come back to look
/// at what they logged, and does it send them anywhere?". Page-load volume is already answerable
/// from the feed's equivalent.
public enum DiaryEvents {
    /// The diary became visible. Once per appearance, not once per page.
    public static func diaryViewed() -> AnalyticsEvent {
        AnalyticsEvent(name: "diary_viewed")
    }

    /// An entry was tapped. `dish_id` is the canonical dish id, so a review of a since-merged dish
    /// reports the survivor.
    ///
    /// **Series break (journal-first):** the name and parameter are unchanged, but the meaning is —
    /// a diary tap now opens *your entry* (``diaryEntryViewed``), not the dish's public page.
    public static func diaryEntryTapped(dishID: UUID) -> AnalyticsEvent {
        AnalyticsEvent(name: "diary_entry_tapped", parameters: ["dish_id": identifier(dishID)])
    }

    /// Your own journal entry appeared (§4). `is_multi_dish_sitting` is the question the entry view
    /// exists to answer for the sitting model: does a log usually produce one dish or several?
    public static func diaryEntryViewed(
        reviewID: UUID,
        dishID: UUID,
        isMultiDishSitting: Bool
    ) -> AnalyticsEvent {
        AnalyticsEvent(
            name: "diary_entry_viewed",
            parameters: [
                "review_id": identifier(reviewID),
                "dish_id": identifier(dishID),
                "is_multi_dish_sitting": isMultiDishSitting ? "true" : "false"
            ]
        )
    }

    /// "See all reviews of this dish" — the explicit crossing from your record to everyone's.
    public static func diaryEntryDishOpened(dishID: UUID) -> AnalyticsEvent {
        AnalyticsEvent(name: "diary_entry_dish_opened", parameters: ["dish_id": identifier(dishID)])
    }

    /// Rule R (§5): a restaurant name was used as a link.
    public static func restaurantNameTapped(from origin: RestaurantLinkOrigin) -> AnalyticsEvent {
        AnalyticsEvent(name: "restaurant_name_tapped", parameters: ["from": origin.rawValue])
    }

    /// Lowercased, matching how Postgres serialises a uuid — so an event id pastes into a query.
    private static func identifier(_ id: UUID) -> String { id.uuidString.lowercased() }
}
