import AteKit
import SwiftUI

// The loading state of the three grouped screens, as their REAL components with placeholder content
// (design-language §5). No bespoke grey rectangles: these are literally `AggregateHero`,
// `ReviewStreamRow`, `DishRowView` and `DishCard`, so the page cannot reflow when the data lands.
//
// Counts are "fill the viewport, no partial row at the fold": four on a stream, three in a group.

/// Dish detail, loading: hero → actions Group → a stream of people.
struct DishDetailSkeleton: View {
    var body: some View {
        List {
            Section {
                AggregateHero(score: 4.6, reviewCount: 12, unratedCaption: "")
            }
            Section {
                LabelledSkeletonRow(title: "Tipo 00", subtitle: "Melbourne")
                LabelledSkeletonRow(title: "Log this dish", subtitle: nil)
            }
            Section {
                ForEach(FeedPlaceholder.reviews(count: 4), id: \.id) { review in
                    ReviewStreamRow(review: review, author: FeedPlaceholder.author)
                        .streamRow(showsDivider: true)
                }
            } header: {
                Text("Reviews")
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Theme.Color.backgroundRecessed)
    }
}

/// Restaurant detail, loading: hero → actions Group → a group of destinations.
struct RestaurantDetailSkeleton: View {
    var body: some View {
        List {
            Section {
                AggregateHero(score: 4.8, reviewCount: 15, unratedCaption: "")
            }
            Section {
                LabelledSkeletonRow(title: "Log a dish", subtitle: nil)
            }
            Section("Dishes") {
                ForEach(FeedPlaceholder.rankedDishes(count: 3)) { dish in
                    DishRowView(dish: dish)
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Theme.Color.backgroundRecessed)
    }
}

/// A journal entry, loading: the one card, then the ways out.
struct DiaryEntrySkeleton: View {
    var body: some View {
        List {
            Section {
                DishCard(model: DishCardModel(FeedPlaceholder.entries(count: 1)[0]), mode: .entry)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
            Section {
                LabelledSkeletonRow(title: "Tipo 00", subtitle: "Melbourne")
                LabelledSkeletonRow(title: "See all reviews of this dish", subtitle: nil)
                LabelledSkeletonRow(title: "Log this again", subtitle: nil)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Theme.Color.backgroundRecessed)
    }
}

/// A group row at the real height, with text of the real length. Shared by all three so the ways-out
/// section is one shape everywhere it's redacted.
private struct LabelledSkeletonRow: View {
    let title: String
    let subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.hairline) {
            Text(title)
                .font(Theme.Text.body)
                .foregroundStyle(Theme.Color.textPrimary)
            if let subtitle {
                Text(subtitle)
                    .font(Theme.Text.caption)
                    .foregroundStyle(Theme.Color.textSecondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
