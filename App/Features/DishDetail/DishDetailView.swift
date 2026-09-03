import AteKit
import SwiftUI

/// **Dish detail** — the screen that answers "should I order this?".
///
/// Header (name, restaurant, aggregate), a log CTA, then every review of the dish, newest first and
/// keyset-paginated. All the behaviour lives in ``DishDetailModel``; this file is layout.
///
/// It is self-contained on purpose: `DishDetailView(dishID:)` is enough to push it from anywhere,
/// and every dependency is an init parameter so Feed, Search and the Log flow can inject their own
/// client, analytics recorder, and log action when they wire up.
struct DishDetailView: View {
    @State private var model: DishDetailModel

    init(
        dishID: UUID,
        source: DetailSource = .unknown,
        dataSource: any DetailDataSource = DetailDataSourceProvider.live,
        analytics: @escaping AnalyticsRecorder = DetailTelemetry.live,
        /// Nil = no log flow wired yet, so the CTA isn't shown. The lead passes the LogSheet
        /// presenter here when it lands; nothing else about this screen changes.
        onLogDish: (@MainActor () -> Void)? = nil
    ) {
        _model = State(wrappedValue: DishDetailModel(
            dishID: dishID,
            source: source,
            dataSource: dataSource,
            analytics: analytics,
            onLogDish: onLogDish
        ))
    }

    var body: some View {
        page
            // §5: redacted real components rather than a spinner, on the same 150/350 clock as
            // every other loading state in the app.
            .skeleton(isLoading: isLoading, label: "Loading this dish") { DishDetailSkeleton() }
            // The chrome lives OUTSIDE the gate: a title that vanished for the length of a skeleton
            // would be the page relayouting, which is the thing skeletons exist to prevent.
            // §2's header signature: the dish name IS the screen, so it's the large title, with the
            // place as the subtitle. Explicit `.large`: a title set after an async load defaults to
            // inline otherwise.
            .navigationTitle(model.dish?.name ?? "")
            .navigationBarTitleDisplayMode(.large)
            .modifier(DetailSubtitle(text: placeSubtitle))
            .task { await model.load() }
    }

    /// Nothing to show yet and nothing to say about why — the one state a skeleton is for.
    private var isLoading: Bool {
        model.restaurant == nil && model.state.errorMessage == nil
    }

    private var page: some View {
        List {
            if let message = model.state.errorMessage, model.dish == nil {
                DetailErrorView(message: message) { await model.reload() }
            } else if let restaurant = model.restaurant {
                header(restaurant: restaurant)
                reviews
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Theme.Color.backgroundRecessed)
        .refreshable { await model.refresh() }
    }

    /// "Chin Chin · Melbourne" under the dish name — the second half of what a dish *is*.
    private var placeSubtitle: String? {
        guard let restaurant = model.restaurant else { return nil }
        guard let suburb = restaurant.locality, !suburb.isEmpty else { return restaurant.name }
        return "\(restaurant.name) · \(suburb)"
    }

    // MARK: - Header

    /// §2: hero on the plane, then exactly ONE Group — the ways out. The restaurant row was already
    /// sharing a section with the aggregate, which made the score look like a fact *of* the row.
    private func header(restaurant: Restaurant) -> some View {
        Group {
            Section {
                AggregateHero(
                    score: model.score,
                    reviewCount: model.reviewCount,
                    unratedCaption: "Nobody's rated this yet"
                )
            }

            Section {
                // Tapping through to the restaurant is the second half of "what should I order
                // here?". Rule R's shared component (§5) rather than a bespoke link, so this row and
                // the place line on a feed card are the same affordance and report the same event.
                RestaurantNameLink(
                    name: restaurant.name,
                    suburb: restaurant.locality,
                    restaurantID: restaurant.id,
                    from: .dishDetail,
                    style: .disclosureRow
                )

                if model.canLogDish {
                    Button("Log this dish", systemImage: "plus.circle") { model.logDishTapped() }
                        .foregroundStyle(Theme.Color.accent)
                }
            }
        }
    }

    // MARK: - Reviews

    /// §2: a PERSON-LED stream on the plane — avatar gutter, full-bleed hairlines, no chevrons.
    /// Deliberately not a Group: these are peers to keep scrolling past, not destinations.
    @ViewBuilder
    private var reviews: some View {
        Section {
            if model.showsEmptyReviewState {
                Text("No reviews yet — be the first to rate it.")
                    .font(Theme.Text.body)
                    .foregroundStyle(Theme.Color.textSecondary)
                    .streamRow(showsDivider: false)
            }

            ForEach(model.reviews, id: \.id) { review in
                ReviewStreamRow(review: review, author: model.author(of: review))
                    .streamRow(showsDivider: review.id != model.reviews.last?.id)
                    // Paging trigger: fires as rows appear, and the model ignores everything that
                    // isn't near the end.
                    .task { await model.loadMoreIfNeeded(currentReviewID: review.id) }
            }

            if model.isLoadingMoreReviews {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Theme.Color.background)
            }
        } header: {
            Text("Reviews")
        }
    }
}

#if DEBUG
#Preview("Rated dish") {
    NavigationStack {
        DishDetailView(
            dishID: PreviewDetailData.ratedDishID,
            source: .feed,
            dataSource: PreviewDetailData.dataSource,
            analytics: DetailTelemetry.none,
            onLogDish: {}
        )
        // Previews register the same destinations the tab roots do, so the restaurant row is
        // tappable here too — a dead link in a preview is how a dead link ships.
        .detailDestinations(source: .feed, context: PreviewDetailData.context(onLogDish: {}))
    }
}

#Preview("Unrated dish (–/5)") {
    NavigationStack {
        DishDetailView(
            dishID: PreviewDetailData.unratedDishID,
            dataSource: PreviewDetailData.dataSource,
            analytics: DetailTelemetry.none
        )
        .detailDestinations(source: .unknown, context: PreviewDetailData.context())
    }
}

#Preview("Merged dish redirects") {
    NavigationStack {
        DishDetailView(
            dishID: PreviewDetailData.tombstonedDishID,
            dataSource: PreviewDetailData.dataSource,
            analytics: DetailTelemetry.none
        )
        .detailDestinations(source: .unknown, context: PreviewDetailData.context())
    }
}
#endif
