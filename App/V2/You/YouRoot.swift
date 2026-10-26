import AteKit
import SwiftUI

/// **The You tab's root** — your own record, quietly: who you are, the three totals, the shape of
/// your scoring and your top dishes. Settings is the one control, a glass disc in the bar; testers
/// also get the bug apart before it (`feedback.html` A, moved from the Journal by
/// `journal-header.html` B). The monthly statement is out of V1.
///
/// Nothing here is an invitation: a journal with nothing in it shows zeros, and the chart is absent
/// until something has been scored — a heading about nothing is helper copy.
struct YouRoot: View {
    let router: TabRouter<YouStores>
    let app: AppModel

    /// How far the glass header has stepped away (0 to 1), as on every other root.
    @State private var barHidden: CGFloat = 0
    /// The bug's Feedback sheet (`feedback.html`), testers only.
    @State private var isSendingFeedback = false
    @State private var feedbackToast: String?
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
            .ateRootBarHiding($barHidden)
            .refreshable { await store.refresh() }
            .onChange(of: router.scrollToTop) { _, _ in
                withAnimation(reduceMotion ? nil : .default) { reader.scrollTo(YouRootIDs.top, anchor: .top) }
            }
        }
        .accessibilityIdentifier("v2.root.you")
        .ateGround()
        // The same glass header as Journal, Feed and Saved: one title, always, stepping away with the
        // page. The native bar's collapse into a small title was You's alone (feedback #4).
        .ateGlassRootHeader(
            title: .text(V2Tab.you.title),
            hidden: barHidden,
            showsApart: showsBug,
            apart: { bug },
            controls: {
                AteGlassItem(icon: .settings, label: "Settings") { router.open(.settings(.root)) }
            }
        )
        .sheet(isPresented: $isSendingFeedback) {
            FeedbackSheet(app: app) { feedbackToast = "Report sent. Thank you." }
        }
        .ateToast($feedbackToast)
        .task {
            await store.loadIfNeeded()
            app.services.analytics(YouEvents.youViewed())
        }
        // A new handle from Settings, or a session that arrived late: the header reads it again.
        .onChange(of: app.handle) { _, _ in Task { await store.refresh() } }
        .onChange(of: app.hasSession) { _, _ in Task { await store.refresh() } }
    }

    // MARK: - The bar

    /// The bug, apart from Settings (`feedback.html` A): TestFlight and Debug builds only, signed in,
    /// never in an App Store build.
    private var showsBug: Bool {
        #if DEBUG || BETA
        app.hasSession
        #else
        false
        #endif
    }

    private var bug: some View {
        Button { isSendingFeedback = true } label: {
            AteIcon.bug.view(size: AteGlassDiscMetrics.glyph)
        }
        .accessibilityLabel("Send feedback")
        .accessibilityIdentifier("you.feedback")
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

    /// "Your top dishes" — up to four, best score first, tilted. A tile opens your own entry, not the
    /// dish's page (Eamon, 22 Oct): for a dish scored more than once, the one behind the tile —
    /// your highest score for it, the newest at that score.
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
                            entryID: dish.entryID,
                            name: dish.dishName,
                            photo: .dish(dish.dishID, name: dish.dishName, cover: dish.coverURL)
                        )
                    },
                    onOpen: { dish in
                        if let entryID = dish.entryID {
                            router.open(.entry(EntryRoute(entryID: entryID)), from: .you)
                        } else {
                            router.open(.dish(dish.dishID), from: .you)
                        }
                    }
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
