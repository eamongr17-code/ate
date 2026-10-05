import Foundation

/// **"Ate with", heard about and answered** — the notifications funnel, built here so the names and
/// parameters are asserted by tests: `notifications_opened → ate_with_opened → ate_with_posted`, with
/// the X (`notification_dismissed`) and the one system ask (`push_permission_result`) beside it.
public enum NotificationEvents {
    /// Where a tag was opened from.
    public enum Source: String, Sendable, CaseIterable {
        case push, list
    }

    /// The list was shown. `unread` is the bell's number at the moment it was opened.
    public static func notificationsOpened(unread: Int) -> AnalyticsEvent {
        AnalyticsEvent(name: "notifications_opened", parameters: ["unread": String(unread)])
    }

    /// A tag's scoring sheet was opened.
    public static func ateWithOpened(from source: Source) -> AnalyticsEvent {
        AnalyticsEvent(name: "ate_with_opened", parameters: ["from": source.rawValue])
    }

    /// The person posted their own entry from a tag: how many of the tagger's dishes they scored,
    /// dropped, or kept unscored, and whether they wrote anything.
    public static func ateWithPosted(scored: Int, removed: Int, unscored: Int, hasWords: Bool) -> AnalyticsEvent {
        AnalyticsEvent(name: "ate_with_posted", parameters: [
            "scored": String(scored),
            "removed": String(removed),
            "unscored": String(unscored),
            "has_words": hasWords ? "true" : "false"
        ])
    }

    /// A row left the list without an answer: the X (`x`), or a swipe's Decline (`decline`).
    public static func notificationDismissed(how: Dismissal) -> AnalyticsEvent {
        AnalyticsEvent(name: "notification_dismissed", parameters: ["how": how.rawValue])
    }

    public enum Dismissal: String, Sendable {
        case close = "x"
        case decline
    }

    /// The system's notification prompt was answered. `trigger` is what asked: opening the list, or tagging someone.
    public static func pushPermissionResult(granted: Bool, trigger: PermissionTrigger) -> AnalyticsEvent {
        AnalyticsEvent(name: "push_permission_result", parameters: [
            "granted": granted ? "true" : "false",
            "trigger": trigger.rawValue
        ])
    }

    /// The Journal's Notifications page was opened: how many rows each of its two groups held.
    public static func notificationsSectionOpened(tags: Int, photos: Int) -> AnalyticsEvent {
        AnalyticsEvent(name: "notifications_section_opened", parameters: [
            "tags": String(max(0, tags)),
            "photos": String(max(0, photos))
        ])
    }

    /// A nearby-place chip on a photo sitting was tapped. `rank` is its position, from 1.
    public static func photoPlaceChipTapped(rank: Int) -> AnalyticsEvent {
        AnalyticsEvent(name: "photo_place_chip_tapped", parameters: ["rank": String(rank)])
    }

    public enum PermissionTrigger: String, Sendable {
        case notifications
        case tag
    }
}
