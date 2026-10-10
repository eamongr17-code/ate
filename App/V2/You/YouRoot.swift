import AteKit
import SwiftUI

/// **The You tab's root** — your own record, quietly: who you are, the three totals, the shape of
/// your scoring and your top dishes. Settings is the one control, a glass disc in the bar. The
/// monthly statement is out of V1.
///
/// Nothing here is an invitation: a journal with nothing in it shows zeros, and the chart is absent
/// until something has been scored — a heading about nothing is helper copy.
struct YouRoot: View {
    let router: TabRouter<YouStores>
    let app: AppModel

    @State private var isCollapsed = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(router: TabRouter<YouStores>, app: AppModel) {
        self.router = router
        self.app = app
    }

    private var store: YouStore { router.stores.you }

    var body: some View {
        ScrollViewReader { reader in
            ScrollView {
                content
                    .id(YouRootIDs.top)
                    .ateAnimation(AteMotion.fillIn, value: store.phase == .loading)
                    .padding(.horizontal, AteMetrics.gutter)
                    .padding(.top, AteMetrics.regular)
                    .padding(.bottom, AteMetrics.section)
            }
            .ateRootCollapse($isCollapsed)
            .refreshable { await store.refresh() }
            .onChange(of: router.scrollToTop) { _, _ in
                withAnimation(reduceMotion ? nil : .default) { reader.scrollTo(YouRootIDs.top, anchor: .top) }
            }
        }
        .accessibilityIdentifier("v2.root.you")
        .ateGround()
        .ateRootToolbar(
            title: .text(V2Tab.you.title),
            inline: AteInlineTitle(title: V2Tab.you.title),
            isCollapsed: isCollapsed
        ) {
            AteGlassItem(icon: .settings, label: "Settings") { router.open(.settings(.root)) }
        }
        .task {
            await store.loadIfNeeded()
            app.services.analytics(YouEvents.youViewed())
        }
        // A new handle from Settings, or a session that arrived late: the header reads it again.
        .onChange(of: app.handle) { _, _ in Task { await store.refresh() } }
        .onChange(of: app.hasSession) { _, _ in Task { await store.refresh() } }
    }

    // MARK: - Bands

    @ViewBuilder
    private var content: some View {
        switch store.phase {
        case .loading:
            skeleton
                .transition(.opacity)
        case .unavailable:
            // No session, or the header would not load: the page says who is missing and stops.
            AteEmptyState(line: "Nobody's\nsigned in.", art: .printer)
                .containerRelativeFrame(.vertical)
                .transition(.opacity)
        case .ready(let summary):
            VStack(alignment: .leading, spacing: AteProfileHeaderMetrics.bandGap) {
                AteProfileHeader(userID: summary.userID, handle: summary.username, city: summary.city,
                                 avatarURL: summary.avatarURL.flatMap(URL.init(string:)))
                AteProfileStats(summary: summary)
                ratings
                topDishes
            }
            .transition(.opacity)
        }
    }

    /// "Your ratings ›" and the chart. Absent until something has been scored.
    @ViewBuilder
    private var ratings: some View {
        if store.histogram.isEmpty == false {
            VStack(alignment: .leading, spacing: AteMetrics.snug) {
                AteBandHeading(title: "Your ratings", identifier: "you.ratings") {
                    // The whole page, from its top: every group, the highest first.
                    guard let score = store.histogram.highestScore else { return }
                    router.open(.ratings(score: score))
                }
                AteScoreHistogram(histogram: store.histogram) { score in
                    router.open(.ratings(score: score))
                }
            }
        }
    }

    /// "Your top dishes" — up to four, best score first, tilted.
    @ViewBuilder
    private var topDishes: some View {
        if store.top.isEmpty == false {
            VStack(alignment: .leading, spacing: AteMetrics.regular) {
                AteBandHeading(title: "Your top dishes")
                AteTopDishes(
                    dishes: store.top.map { dish in
                        AteTopDishes.Dish(
                            id: dish.id,
                            dishID: dish.dishID,
                            name: dish.dishName,
                            photo: .dish(dish.dishID, name: dish.dishName, cover: dish.coverURL)
                        )
                    },
                    onOpen: { router.open(.dish($0)) }
                )
            }
        }
    }

    /// The whole page before it has arrived — every band as its still shape, then one fade.
    private var skeleton: some View {
        VStack(alignment: .leading, spacing: AteProfileHeaderMetrics.bandGap) {
            AteProfileHeaderSkeleton()
            AteProfileStats(summary: nil)
            AteScoreHistogramSkeleton()
            AteTopDishesSkeleton()
        }
        .accessibilityHidden(true)
    }
}

private enum YouRootIDs {
    static let top = "you.top"
}
