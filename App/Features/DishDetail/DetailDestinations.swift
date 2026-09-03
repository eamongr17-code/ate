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

    // MARK: Diary entry seams (§4)
    //
    // The entry view is normally resolved with NO network: the review is already on the diary's
    // loaded page, so pushing an entry is instant and cannot fail. These three closures are how it
    // asks, without ``DiaryEntryView`` having to know that ``DiaryStore`` exists — which also keeps
    // the diary's paging store free of a by-id index it would otherwise grow just for this screen.

    /// The already-loaded review, by id. Nil closure (or a nil result) falls through to
    /// ``entryFetcher``.
    let diaryEntry: (@MainActor (UUID) -> FeedEntry?)?
    /// The OTHER dishes of the same sitting, newest first, excluding the entry itself. Defaults to
    /// none — the "Part of a sitting at …" block simply doesn't render, which is also the correct
    /// answer for a single-dish sitting and for an entry reached from outside the diary.
    let diarySittingSiblings: (@MainActor (UUID) -> [FeedEntry])?
    /// The by-id read, for an entry reached from outside the diary (a deep link, a restored path).
    let entryFetcher: (any DiaryEntryFetching)?
    /// Opens the Log sheet pre-resolved — "Log this again" (§4). Nil hides the row rather than
    /// showing one that does nothing.
    let onLogAgain: (@MainActor (LogEntry) -> Void)?

    init(
        dataSource: any DetailDataSource,
        analytics: @escaping AnalyticsRecorder = DetailTelemetry.live,
        onLogDish: (@MainActor () -> Void)? = nil,
        diaryEntry: (@MainActor (UUID) -> FeedEntry?)? = nil,
        diarySittingSiblings: (@MainActor (UUID) -> [FeedEntry])? = nil,
        entryFetcher: (any DiaryEntryFetching)? = nil,
        onLogAgain: (@MainActor (LogEntry) -> Void)? = nil
    ) {
        self.dataSource = dataSource
        self.analytics = analytics
        self.onLogDish = onLogDish
        self.diaryEntry = diaryEntry
        self.diarySittingSiblings = diarySittingSiblings
        self.entryFetcher = entryFetcher
        self.onLogAgain = onLogAgain
    }

    /// Built from the app's single shared API client — one client, one URLSession, one auth session
    /// for feed, search and detail alike.
    static func live(api: AteAPIClient) -> DetailContext {
        DetailContext(dataSource: AteDetailClient(api: api), entryFetcher: DiaryEntryClient(api: api))
    }

    /// The same context with the diary seams filled in. The tab scaffold calls this once it has the
    /// store — a method rather than more `init` parameters at the call site, so wiring the diary is
    /// one line and the rest of the context is built exactly as every other tab builds it.
    func withDiary(
        entry: @escaping @MainActor (UUID) -> FeedEntry?,
        siblings: @escaping @MainActor (UUID) -> [FeedEntry],
        onLogAgain: (@MainActor (LogEntry) -> Void)? = nil
    ) -> DetailContext {
        DetailContext(
            dataSource: dataSource,
            analytics: analytics,
            onLogDish: onLogDish,
            diaryEntry: entry,
            diarySittingSiblings: siblings,
            entryFetcher: entryFetcher,
            onLogAgain: onLogAgain ?? self.onLogAgain
        )
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
            .navigationDestination(for: DiaryEntryRoute.self) { route in
                DiaryEntryView(reviewID: route.reviewID, context: context)
            }
    }
}
