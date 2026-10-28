import Foundation

/// **Plate awards** — does an award bring people back, and do they share it? Built here so the
/// names and parameters are asserted by tests and can never drift.
public enum AwardEvents {

    /// Where an award was opened from.
    public enum Source: String, Sendable, CaseIterable {
        case takeover
        case you
        case profile
        case awardsPage = "awards_page"
    }

    /// The takeover came up. `count` = how many awards it holds; `award` = the first (newest).
    public static func takeoverShown(award: PlateAward, count: Int) -> AnalyticsEvent {
        AnalyticsEvent(name: "award_takeover_shown", parameters: ["award": award.rawValue, "count": String(count)])
    }

    /// One award's page in the takeover was seen.
    public static func earned(award: PlateAward) -> AnalyticsEvent {
        AnalyticsEvent(name: "award_earned_seen", parameters: ["award": award.rawValue])
    }

    /// An award was opened. `isMe` = your own, not someone else's.
    public static func opened(award: PlateAward, source: Source, isMe: Bool) -> AnalyticsEvent {
        AnalyticsEvent(name: "award_opened", parameters: [
            "award": award.rawValue, "source": source.rawValue, "is_me": isMe ? "true" : "false"
        ])
    }

    /// The Awards page was opened.
    public static func pageViewed(isMe: Bool, earned: Int) -> AnalyticsEvent {
        AnalyticsEvent(
            name: "awards_page_viewed",
            parameters: ["is_me": isMe ? "true" : "false", "earned": String(earned)]
        )
    }

    /// The plate was turned over to its back.
    public static func turnedOver(award: PlateAward) -> AnalyticsEvent {
        AnalyticsEvent(name: "award_turned_over", parameters: ["award": award.rawValue])
    }

    /// The story card was shared.
    public static func shared(award: PlateAward, source: Source) -> AnalyticsEvent {
        AnalyticsEvent(name: "award_shared", parameters: ["award": award.rawValue, "source": source.rawValue])
    }
}
