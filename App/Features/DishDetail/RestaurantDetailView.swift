import AteKit
import SwiftUI

/// **Restaurant detail** — name, suburb, the house rating, and the menu ranked by what people
/// actually order and rate.
///
/// The rating shown is `restaurant_stats.avg_rating`, the server's mean of per-dish averages
/// (data-model §1.2). Nothing here averages anything: computing it from the dish list on screen
/// would produce a different number, which is exactly the bug the legacy client shipped.
struct RestaurantDetailView: View {
    @State private var model: RestaurantDetailModel

    init(
        restaurantID: UUID,
        source: DetailSource = .unknown,
        dataSource: any DetailDataSource = DetailDataSourceProvider.live,
        analytics: @escaping AnalyticsRecorder = DetailTelemetry.live,
        onLogDish: (@MainActor () -> Void)? = nil
    ) {
        _model = State(wrappedValue: RestaurantDetailModel(
            restaurantID: restaurantID,
            source: source,
            dataSource: dataSource,
            analytics: analytics,
            onLogDish: onLogDish
        ))
    }

    var body: some View {
        List {
            if let message = model.state.errorMessage, model.restaurant == nil {
                DetailErrorView(message: message) { await model.refresh() }
            } else if let restaurant = model.restaurant {
                header(restaurant)
                dishes
            } else {
                DetailLoadingView()
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Theme.Color.backgroundRecessed)
        // §2: same header shape as a dish — both are "a public thing with an aggregate". Explicit
        // `.large`: a title set after an async load defaults to inline otherwise.
        .navigationTitle(model.restaurant?.name ?? "")
        .navigationBarTitleDisplayMode(.large)
        .modifier(DetailSubtitle(text: model.restaurant?.locality))
        .refreshable { await model.refresh() }
        .task { await model.load() }
    }

    // MARK: - Header

    /// Hero on the plane, then exactly ONE actions Group. The suburb rides in the subtitle now, so
    /// the hero is the score and nothing else.
    @ViewBuilder
    private func header(_ restaurant: Restaurant) -> some View {
        Section {
            AggregateHero(
                score: model.avgRating,
                reviewCount: model.reviewCount,
                unratedCaption: "No dishes rated here yet"
            )
        }

        if model.canLogDish {
            Section {
                Button("Log a dish", systemImage: "plus.circle") { model.logDishTapped() }
                    .foregroundStyle(Theme.Color.accent)
            }
        }
    }

    // MARK: - Menu

    /// §2: where a dish page's body is a stream of PEOPLE, a restaurant's is a group of
    /// DESTINATIONS — filled 56pt tiles, system inset separators, a chevron on every row. The two
    /// screens share a header and diverge below it, which is what tells you which one you're on.
    @ViewBuilder
    private var dishes: some View {
        Section("Dishes") {
            if model.showsEmptyDishState {
                Text("No dishes here yet — log the first one.")
                    .font(Theme.Text.body)
                    .foregroundStyle(Theme.Color.textSecondary)
            }

            ForEach(model.dishes) { dish in
                // A value push, resolved by the hosting stack's `detailDestinations` — identical
                // whether this screen was reached from Feed, Search or (later) the receipt.
                NavigationLink(value: DishRoute(dishID: dish.id)) {
                    DishRowView(dish: dish)
                }
            }
        }
    }
}

#if DEBUG
#Preview("Rated restaurant") {
    NavigationStack {
        RestaurantDetailView(
            restaurantID: PreviewDetailData.restaurantID,
            source: .search,
            dataSource: PreviewDetailData.dataSource,
            analytics: DetailTelemetry.none,
            onLogDish: {}
        )
        .detailDestinations(source: .search, context: PreviewDetailData.context(onLogDish: {}))
    }
}

#Preview("Unrated restaurant (–/5)") {
    NavigationStack {
        RestaurantDetailView(
            restaurantID: PreviewDetailData.unratedRestaurantID,
            dataSource: PreviewDetailData.dataSource,
            analytics: DetailTelemetry.none
        )
        .detailDestinations(source: .unknown, context: PreviewDetailData.context())
    }
}
#endif
