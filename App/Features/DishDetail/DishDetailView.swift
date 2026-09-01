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
        List {
            if let message = model.state.errorMessage, model.dish == nil {
                DetailErrorView(message: message) { await model.reload() }
            } else if let restaurant = model.restaurant {
                header(restaurant: restaurant)
                if model.canLogDish {
                    Section { LogDishButton(title: "Log this dish") { model.logDishTapped() } }
                }
                reviews
            } else {
                DetailLoadingView()
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Theme.Color.backgroundGrouped)
        // The dish name IS the screen, so it's the large title — it collapses into the bar on
        // scroll for free, which is why there's no second copy of the name inside the list.
        // Explicit `.large`: a title set after an async load defaults to inline otherwise.
        .navigationTitle(model.dish?.name ?? "")
        .navigationBarTitleDisplayMode(.large)
        .refreshable { await model.refresh() }
        .task { await model.load() }
    }

    // MARK: - Header

    private func header(restaurant: Restaurant) -> some View {
        Section {
            AggregateScoreView(
                score: model.score,
                reviewCount: model.reviewCount,
                unratedCaption: "Nobody's rated this yet"
            )
            .padding(.vertical, Theme.Spacing.snug)

            // Tapping through to the restaurant is the second half of "what should I order here?" —
            // a plain navigation row, so it behaves like every other disclosure in the app. It
            // pushes a *value*: the hosting stack's `detailDestinations` builds the screen, which is
            // what keeps the dependencies and the funnel `source` identical however deep we are.
            NavigationLink(value: RestaurantRoute(restaurantID: restaurant.id)) {
                VStack(alignment: .leading, spacing: Theme.Spacing.hairline) {
                    Text(restaurant.name)
                        .font(Theme.Text.itemTitle)
                        .foregroundStyle(Theme.Color.textPrimary)
                    if let suburb = restaurant.locality {
                        Text(suburb)
                            .font(Theme.Text.caption)
                            .foregroundStyle(Theme.Color.textSecondary)
                    }
                }
            }
        }
    }

    // MARK: - Reviews

    @ViewBuilder
    private var reviews: some View {
        Section("Reviews") {
            if model.showsEmptyReviewState {
                Text("No reviews yet — be the first to rate it.")
                    .font(Theme.Text.body)
                    .foregroundStyle(Theme.Color.textSecondary)
            }

            ForEach(model.reviews, id: \.id) { review in
                ReviewRowView(review: review, author: model.author(of: review))
                    // Paging trigger: fires as rows appear, and the model ignores everything that
                    // isn't near the end.
                    .task { await model.loadMoreIfNeeded(currentReviewID: review.id) }
            }

            if model.isLoadingMoreReviews {
                ProgressView()
                    .frame(maxWidth: .infinity)
            }
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
