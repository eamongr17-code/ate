import AteKit
import SwiftUI

/// The head of a sitting block: where you were, and when (§3.2).
///
/// The header as a whole is not a tap target — only the restaurant name is (Rule R). A header that
/// opened *something* on any tap would make the date look like a filter, and there is no such thing.
///
/// §10.9: at large Dynamic Type the date drops to a second line rather than squeezing the restaurant
/// name into an ellipsis. The name is the part that identifies the block; the date is context.
struct DiarySittingHeader: View {
    let sitting: DiarySitting
    /// Opens the restaurant. A closure rather than a `NavigationLink`, because a link *inside* a list
    /// row is a row link as far as `List` is concerned: it draws a disclosure chevron in the middle
    /// of the header and claims the whole row's tap. Rule R wants an inner target on the name only.
    /// (Lane B's shared `RestaurantNameLink` replaces this body; the seam is already the right shape.)
    let onOpenRestaurant: @MainActor (RestaurantRoute) -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.snug) {
                name
                Spacer(minLength: Theme.Spacing.snug)
                date
            }
            VStack(alignment: .leading, spacing: Theme.Spacing.hairline) {
                name
                date
            }
        }
    }

    /// The one tap target on the header. The date beside it is context, not a control.
    private var name: some View {
        Button {
            onOpenRestaurant(RestaurantRoute(restaurantID: sitting.restaurant.id))
        } label: {
            Text(placeLine)
                .font(Theme.Text.sectionTitle)
                .foregroundStyle(Theme.Color.textPrimary)
                .lineLimit(2)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens \(sitting.restaurant.name)")
    }

    private var date: some View {
        Text(dateText)
            .font(Theme.Text.caption)
            .foregroundStyle(Theme.Color.textSecondary)
    }

    /// "Tipo 00 · Carlton", or just the name when the restaurant has no locality — never a dangling
    /// separator.
    private var placeLine: String {
        guard let locality = sitting.restaurant.locality else { return sitting.restaurant.name }
        return "\(sitting.restaurant.name) · \(locality)"
    }

    /// "Today" / "Yesterday" / "Fri 12 Sep". The *rule* is in AteKit; the wording is here so it
    /// follows the reader's locale and calendar.
    private var dateText: String {
        switch DiaryDayLabel.of(sitting.newestAt) {
        case .today: "Today"
        case .yesterday: "Yesterday"
        case .date(let date): date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
        }
    }
}
