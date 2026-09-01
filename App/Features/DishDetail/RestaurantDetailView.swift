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

    private let dataSource: any DetailDataSource
    private let analytics: AnalyticsRecorder
    private let onLogDish: (@MainActor () -> Void)?

    init(
        restaurantID: UUID,
        source: DetailSource = .unknown,
        dataSource: any DetailDataSource = DetailDataSourceProvider.live,
        analytics: @escaping AnalyticsRecorder = DetailTelemetry.live,
        onLogDish: (@MainActor () -> Void)? = nil
    ) {
        self.dataSource = dataSource
        self.analytics = analytics
        self.onLogDish = onLogDish
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
                if model.canLogDish {
                    Section { LogDishButton(title: "Log a dish") { model.logDishTapped() } }
                }
                dishes
            } else {
                DetailLoadingView()
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Theme.Color.backgroundGrouped)
        // Explicit `.large`: a title set after an async load defaults to inline otherwise.
        .navigationTitle(model.restaurant?.name ?? "")
        .navigationBarTitleDisplayMode(.large)
        .refreshable { await model.refresh() }
        .task { await model.load() }
    }

    // MARK: - Header

    private func header(_ restaurant: Restaurant) -> some View {
        Section {
            VStack(alignment: .leading, spacing: Theme.Spacing.regular) {
                // The name is the large title; the suburb is the line that disambiguates two
                // restaurants with the same name, so it stays in the content.
                if let suburb = restaurant.locality {
                    Text(suburb)
                        .font(Theme.Text.detail)
                        .foregroundStyle(Theme.Color.textSecondary)
                }

                AggregateScoreView(
                    score: model.avgRating,
                    reviewCount: model.reviewCount,
                    unratedCaption: "No dishes rated here yet"
                )
            }
            .padding(.vertical, Theme.Spacing.snug)
        }
    }

    // MARK: - Menu

    @ViewBuilder
    private var dishes: some View {
        Section("Dishes") {
            if model.showsEmptyDishState {
                Text("No dishes here yet — log the first one.")
                    .font(Theme.Text.body)
                    .foregroundStyle(Theme.Color.textSecondary)
            }

            ForEach(model.dishes) { dish in
                NavigationLink {
                    DishDetailView(
                        dishID: dish.id,
                        dataSource: dataSource,
                        analytics: analytics,
                        onLogDish: onLogDish
                    )
                } label: {
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
    }
}

#Preview("Unrated restaurant (–/5)") {
    NavigationStack {
        RestaurantDetailView(
            restaurantID: PreviewDetailData.unratedRestaurantID,
            dataSource: PreviewDetailData.dataSource,
            analytics: DetailTelemetry.none
        )
    }
}
#endif
