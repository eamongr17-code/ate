import Foundation

/// **The dish map's events** (0088): opened from the Feed, a place tapped, the phone found again.
/// Opening a dish or a place from it is the detail events' own `*_viewed`, with `source: map`.
public enum MapEvents {
    /// The map button on the Feed.
    public static func opened() -> AnalyticsEvent {
        AnalyticsEvent(name: "map_opened")
    }

    /// A pin or a dot tapped. `dishes` is bucketed ("1", "2-4", "5+"): how much a place had to show.
    public static func placeSelected(dishCount: Int) -> AnalyticsEvent {
        let bucket = switch dishCount {
        case ...1: "1"
        case 2...4: "2-4"
        default: "5+"
        }
        return AnalyticsEvent(name: "map_place_selected", parameters: ["dishes": bucket])
    }

    /// Show my location.
    public static func recentred() -> AnalyticsEvent {
        AnalyticsEvent(name: "map_recentred")
    }
}
