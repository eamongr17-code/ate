import AteKit
import Foundation
import TelemetryDeck

/// Ships the feed's three funnel signals. The names are the brief's, verbatim; the store decides
/// *when* they fire (and tests assert that), this only decides *how* they leave the device.
///
/// TelemetryDeck parameters are strings, so numbers are formatted here rather than at call sites.
struct TelemetryDeckFeedAnalytics: FeedAnalyticsReporting {
    func feedViewed() {
        TelemetryDeck.signal("feed_viewed")
    }

    func feedPageLoaded(page: Int, itemCount: Int) {
        TelemetryDeck.signal(
            "feed_page_loaded",
            parameters: ["page": String(page), "item_count": String(itemCount)]
        )
    }

    func feedDishTapped(dishID: UUID, position: Int) {
        TelemetryDeck.signal(
            "feed_dish_tapped",
            parameters: ["dish_id": dishID.uuidString, "position": String(position)]
        )
    }
}
