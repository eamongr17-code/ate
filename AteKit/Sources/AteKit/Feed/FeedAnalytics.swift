import Foundation

/// The three funnel events the feed emits. A protocol rather than direct TelemetryDeck calls for
/// two reasons: AteKit stays free of the SDK, and the event names/parameters become assertable in
/// tests instead of being a thing we hope fires.
///
/// Naming is snake_case to match the existing `app_launched` signal.
public protocol FeedAnalyticsReporting: Sendable {
    /// The feed surface became visible. Once per appearance, not once per page.
    func feedViewed()
    /// A page of entries landed. `page` is 1-based and resets on refresh.
    func feedPageLoaded(page: Int, itemCount: Int)
    /// A row was tapped. `position` is the 0-based index in the *currently loaded* list.
    func feedDishTapped(dishID: UUID, position: Int)
}

/// Default for previews, tests, and any build without a TelemetryDeck app id.
public struct NoOpFeedAnalytics: FeedAnalyticsReporting {
    public init() {}
    public func feedViewed() {}
    public func feedPageLoaded(page: Int, itemCount: Int) {}
    public func feedDishTapped(dishID: UUID, position: Int) {}
}
