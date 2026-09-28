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
}
