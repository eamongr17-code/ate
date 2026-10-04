import Foundation

/// **The Feed's edition** (round 8) — which sections are read, which ones close the loop with a save,
/// and how many cravings people follow. `feed_viewed` and `save_toggled` (``SocialEvents``) still fire;
/// these say *which part of the edition* did it.
public enum FeedEvents {
    /// The edition's sections, as the events name them.
    public enum Section: String, Sendable, CaseIterable {
        case topAte = "top_ate"
        case becauseYouLoved = "because_you_loved"
        case newToRecord = "new_to_record"
        case cravingShelf = "craving_shelf"
        case latestReceipts = "latest_receipts"
        case caughtUp = "caught_up"
    }

    /// A section came on screen — once per section per read of the edition.
    public static func sectionViewed(_ section: Section) -> AnalyticsEvent {
        AnalyticsEvent(name: "feed_section_viewed", parameters: ["section": section.rawValue])
    }

    /// A dish was saved in place from a section (a save, not an unsave).
    public static func dishSaved(_ section: Section) -> AnalyticsEvent {
        AnalyticsEvent(name: "feed_dish_saved", parameters: ["section": section.rawValue])
    }

    /// The cravings picker saved a set — how many are followed now.
    public static func cravingsSet(count: Int) -> AnalyticsEvent {
        AnalyticsEvent(name: "cravings_set", parameters: ["count": String(max(0, count))])
    }

    /// Where a category was followed or unfollowed (4 Oct): the Feed's one-time card, a category's
    /// own page, or the What you follow list.
    public enum CravingSource: String, Sendable, CaseIterable {
        case ask
        case tagPage = "tag_page"
        case following
    }

    /// One category followed — and how many are followed now.
    public static func cravingFollowed(_ source: CravingSource, count: Int) -> AnalyticsEvent {
        AnalyticsEvent(name: "craving_followed", parameters: [
            "source": source.rawValue, "count": String(max(0, count))
        ])
    }

    /// One category unfollowed — and how many are left.
    public static func cravingUnfollowed(_ source: CravingSource, count: Int) -> AnalyticsEvent {
        AnalyticsEvent(name: "craving_unfollowed", parameters: [
            "source": source.rawValue, "count": String(max(0, count))
        ])
    }

    /// The What you follow list was reordered.
    public static func cravingsReordered(count: Int) -> AnalyticsEvent {
        AnalyticsEvent(name: "cravings_reordered", parameters: ["count": String(max(0, count))])
    }

    /// "What do you crave?" came on screen — once per visit, and only ever for one first time.
    public static func cravingsAskShown(options: Int) -> AnalyticsEvent {
        AnalyticsEvent(name: "cravings_ask_shown", parameters: ["options": String(max(0, options))])
    }

    /// A pill on the card was tapped to follow — the how-many-th pick it was.
    public static func cravingsAskPicked(pick: Int) -> AnalyticsEvent {
        AnalyticsEvent(name: "cravings_ask_picked", parameters: ["pick": String(max(0, pick))])
    }

    /// The card's close — after how many picks.
    public static func cravingsAskDismissed(picks: Int) -> AnalyticsEvent {
        AnalyticsEvent(name: "cravings_ask_dismissed", parameters: ["picks": String(max(0, picks))])
    }

    /// The What you follow row at the end of the edition, opened.
    public static func followingOpened(count: Int) -> AnalyticsEvent {
        AnalyticsEvent(name: "following_opened", parameters: ["count": String(max(0, count))])
    }
}
