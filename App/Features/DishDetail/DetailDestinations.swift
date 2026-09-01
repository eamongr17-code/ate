import AteKit
import SwiftUI

/// What a navigation stack needs in order to open a detail screen: where the data comes from, where
/// the funnel events go, and — later — how to present the Log sheet.
///
/// It is a plain value carried by whoever owns the stack (the tab root), not an environment
/// singleton, so previews and Debug drives substitute fixtures by construction rather than by luck.
struct DetailContext {
    let dataSource: any DetailDataSource
    let analytics: AnalyticsRecorder
    /// Nil = the Log flow isn't wired yet, so both detail screens hide their CTA. The Log build
    /// passes its sheet presenter here; nothing else about the detail screens changes.
    let onLogDish: (@MainActor () -> Void)?

    init(
        dataSource: any DetailDataSource,
        analytics: @escaping AnalyticsRecorder = DetailTelemetry.live,
        onLogDish: (@MainActor () -> Void)? = nil
    ) {
        self.dataSource = dataSource
        self.analytics = analytics
        self.onLogDish = onLogDish
    }

    /// Built from the app's single shared API client — one client, one URLSession, one auth session
    /// for feed, search and detail alike.
    static func live(api: AteAPIClient) -> DetailContext {
        DetailContext(dataSource: AteDetailClient(api: api))
    }
}

extension View {
    /// Registers the dish and restaurant destinations for the stack this modifier is applied in.
    ///
    /// **Once per `NavigationStack`, at its root.** Every push inside the stack — a feed row, a
    /// search result, a dish's restaurant header, a restaurant's dish row — is a ``DishRoute`` or
    /// ``RestaurantRoute`` value resolved here, so a screen never has to know how to build the next
    /// one and there is exactly one place per stack that decides how detail screens are constructed.
    ///
    /// `source` is the stack's **entry point** (feed tab vs search tab), which is the funnel question
    /// `dish_detail_viewed` exists to answer; it therefore stays constant as the user drills deeper
    /// within the same stack.
    func detailDestinations(source: DetailSource, context: DetailContext) -> some View {
        self
            .navigationDestination(for: DishRoute.self) { route in
                DishDetailView(
                    dishID: route.dishID,
                    source: source,
                    dataSource: context.dataSource,
                    analytics: context.analytics,
                    onLogDish: context.onLogDish
                )
            }
            .navigationDestination(for: RestaurantRoute.self) { route in
                RestaurantDetailView(
                    restaurantID: route.restaurantID,
                    source: source,
                    dataSource: context.dataSource,
                    analytics: context.analytics,
                    onLogDish: context.onLogDish
                )
            }
    }
}
