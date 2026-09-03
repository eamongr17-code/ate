import AteKit
import SwiftUI

/// **Rule R (§5): wherever a restaurant name is rendered and a `restaurant.id` is in hand, it opens
/// the restaurant.** One component, used at every site, so the affordance can't be right in four
/// places and missing in the fifth.
///
/// Two forms, because two kinds of row need it:
///  - ``Style/disclosureRow`` — the name IS the row (dish detail header, the entry view's onward
///    links). Full-width target, trailing chevron.
///  - ``Style/inline`` — the name is a *fragment* of a row whose own tap does something else (a feed
///    card opens the dish; the receipt's place line sits inside an artifact). The link is an inner
///    `Button(.plain)` with its own `contentShape`, which is what makes a nested target land: the
///    host's row tap must be an `onTapGesture` on a shaped container, never an outer `Button`, or
///    the outer button swallows every touch inside it.
///
/// **How it navigates.** It can't push by itself — `DishDetailView` is pushed *into* whatever stack
/// is hosting it and never sees that stack's path. So the push arrives as an environment action the
/// stack root installs (``SwiftUI/View/stackRouting(path:analytics:)``), in the shape SwiftUI uses
/// for `openURL`: one place per stack decides how a restaurant is reached, and every depth inherits
/// it. Where no action is installed (previews, a host not yet wired) it degrades to a stock
/// `NavigationLink` — the navigation always works; only the tap event is lost.
struct RestaurantNameLink: View {
    enum Style {
        /// A row of its own, with a chevron.
        case disclosureRow
        /// An inner target inside a denser row.
        case inline
    }

    let name: String
    let suburb: String?
    let restaurantID: UUID
    /// Which site this is, for `restaurant_name_tapped` (§9).
    let from: RestaurantLinkOrigin
    var style: Style = .inline
    /// Inline only: the host's own type/colour for the line it sits in, so the link reads as text
    /// rather than as a control bolted into a card.
    var font: Font = Theme.Text.detail
    var foreground: Color = Theme.Color.textSecondary

    @Environment(\.openRestaurant) private var openRestaurant

    var body: some View {
        if openRestaurant.isWired {
            Button {
                openRestaurant(restaurantID, from: from)
            } label: {
                label
            }
            .buttonStyle(.plain)
            .contentShape(.rect)
            .accessibilityLabel(accessibilityLabel)
            .accessibilityAddTraits(.isButton)
        } else if style == .disclosureRow {
            NavigationLink(value: RestaurantRoute(restaurantID: restaurantID)) {
                label
            }
            .accessibilityLabel(accessibilityLabel)
        } else {
            // An unwired INLINE link degrades to plain text, never to a `NavigationLink`: nested
            // inside a list row a link would be promoted to the whole row (opening the restaurant
            // when the person meant the dish), and inside the receipt's exported artifact there is
            // no stack to push into at all. A dead affordance is worse than no affordance.
            label
        }
    }

    /// "Open Tipo 00" — the same words the row's context menu and VoiceOver custom action use, so
    /// the three routes to the restaurant are one thing to a screen-reader user, not three.
    private var accessibilityLabel: String { "Open \(name)" }

    @ViewBuilder
    private var label: some View {
        switch style {
        case .inline:
            Text(placeLine)
                .font(font)
                .foregroundStyle(foreground)
                .lineLimit(1)
        case .disclosureRow:
            HStack(spacing: Theme.Spacing.snug) {
                VStack(alignment: .leading, spacing: Theme.Spacing.hairline) {
                    Text(name)
                        .font(Theme.Text.itemTitle)
                        .foregroundStyle(Theme.Color.textPrimary)
                    if let suburb, !suburb.isEmpty {
                        Text(suburb)
                            .font(Theme.Text.caption)
                            .foregroundStyle(Theme.Color.textSecondary)
                    }
                }
                Spacer(minLength: Theme.Spacing.snug)
                // Drawn rather than inherited: this branch is a Button, and a Button in a List gets
                // no disclosure indicator of its own. The NavigationLink branch gets the system's.
                if openRestaurant.isWired {
                    Image(systemName: "chevron.forward")
                        .font(Theme.Text.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(Theme.Color.textTertiary)
                }
            }
            .contentShape(.rect)
        }
    }

    /// "Tipo 00 · Carlton", or just the name. Never a dangling separator.
    private var placeLine: String {
        guard let suburb, !suburb.isEmpty else { return name }
        return "\(name) · \(suburb)"
    }
}
