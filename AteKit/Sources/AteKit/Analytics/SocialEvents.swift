import Foundation

/// Where a save was made. A closed set, because the question the funnel asks is *where the loop
/// closes*: a save in the feed is somebody deciding where to eat next, a save on an entry page is
/// somebody who read the whole thing, and a tap in the Saved list is only ever an unsave.
public enum SaveSource: String, Sendable, CaseIterable, Codable {
    case feed
    /// Someone else's entry page — a dish row, or the bookmark in its top bar.
    case entry
    case savedList = "saved_list"
    /// A profile's slips.
    case profile
    /// A place page — the bookmark on one of its entries.
    case place
    /// A dish page — the one bookmark in its top bar.
    case dish
    /// The Search tab's Saved segment — the shelf's own row, found by typing.
    case search
}

/// **The feed and the save loop's funnel.** Built here so the names and parameters are asserted by
/// tests and can never drift, and sent by the app target's ``AnalyticsRecorder``.
///
/// `feed_viewed → feed_page_loaded → save_toggled` is the loop PRODUCT.md is betting on ("saves per
/// feed session"), and `profile_viewed` is the one branch off it. The moderation events are not
/// growth metrics — they are the tripwire that tells us a seeded cohort has gone wrong, which is
/// worth knowing on the day it happens rather than in a support email.
public enum SocialEvents {

    /// The feed became visible. Once per appearance, not once per page.
    public static func feedViewed() -> AnalyticsEvent {
        AnalyticsEvent(name: "feed_viewed")
    }

    /// A page landed. `page` is 1-based and resets on refresh, so page 1 counts sessions and
    /// anything above it counts depth.
    public static func feedPageLoaded(page: Int, itemCount: Int) -> AnalyticsEvent {
        AnalyticsEvent(
            name: "feed_page_loaded",
            parameters: ["page": String(max(1, page)), "items": String(max(0, itemCount))]
        )
    }

    /// A bookmark was tapped. Fired **optimistically**, at the tap, because the tap is the intent —
    /// and the number we act on is how often people save, not how often the network agreed.
    public static func saveToggled(source: SaveSource, isSaved: Bool) -> AnalyticsEvent {
        AnalyticsEvent(
            name: "save_toggled",
            parameters: ["source": source.rawValue, "state": isSaved ? "on" : "off"]
        )
    }

    /// Someone else's page was opened. `is_me` separates the You tab's own read from a real visit.
    public static func profileViewed(isMe: Bool) -> AnalyticsEvent {
        AnalyticsEvent(name: "profile_viewed", parameters: ["is_me": isMe ? "true" : "false"])
    }

    public static func userBlocked() -> AnalyticsEvent {
        AnalyticsEvent(name: "user_blocked")
    }

    public static func entryReported() -> AnalyticsEvent {
        AnalyticsEvent(name: "entry_reported")
    }

    public static func profileReported() -> AnalyticsEvent {
        AnalyticsEvent(name: "profile_reported")
    }
}
