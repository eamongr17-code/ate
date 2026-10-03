import AteKit
import SwiftUI

/// **Your own header on You** — a 56pt avatar and the handle on ONE line that ends in an ellipsis
/// when it is long, the city muted under it (Eamon's resized header, 26 Sep). The settings control
/// is the root's toolbar disc, not part of this row.
struct AteProfileHeader: View {
    let userID: UUID
    let handle: String
    var city: String?

    @Environment(\.atePalette) private var palette

    var body: some View {
        HStack(spacing: AteMetrics.regular) {
            AteAvatar(
                userID: userID,
                handle: handle,
                side: AteProfileHeaderMetrics.avatar,
                textStyle: .avatarMonogramCompact
            )
            VStack(alignment: .leading, spacing: AteMetrics.hairspace) {
                Text(verbatim: "@\(handle)")
                    .ateText(.youHandleCompact)
                    .foregroundStyle(palette.fg)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let city, city.isEmpty == false {
                    Text(city)
                        .ateText(.meta)
                        .foregroundStyle(palette.muted)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }
}

/// The header before it has arrived — the avatar's disc and the shape of a name, breathing.
struct AteProfileHeaderSkeleton: View {
    var breathes = true

    @Environment(\.atePalette) private var palette

    var body: some View {
        HStack(spacing: AteMetrics.regular) {
            Circle()
                .fill(palette.hairline)
                .frame(width: AteProfileHeaderMetrics.avatar, height: AteProfileHeaderMetrics.avatar)
            VStack(alignment: .leading, spacing: AteMetrics.snug) {
                AteSkeletonBar(
                    width: AteProfileHeaderMetrics.nameBar,
                    height: AteProfileHeaderMetrics.nameBarHeight,
                    palette: palette
                )
                AteSkeletonBar(
                    width: AteProfileHeaderMetrics.cityBar,
                    height: AteProfileHeaderMetrics.cityBarHeight,
                    palette: palette
                )
            }
            Spacer(minLength: 0)
        }
        .ateBreathing(breathes)
        .accessibilityHidden(true)
    }
}

/// **The three totals** — orders, places, dishes on the whole slip — as You and somebody else's
/// page both print them, and its still shape while they load.
struct AteProfileStats: View {
    /// `nil` draws the slip's shape with dashes, breathing.
    let summary: ProfileSummary?

    var body: some View {
        if let summary {
            AteStatsSlip(cells: [
                (summary.orders.formatted(), "Orders"),
                (summary.places.formatted(), "Places"),
                (summary.dishes.formatted(), "Dishes")
            ])
        } else {
            AteStatsSlip(cells: [("—", "Orders"), ("—", "Places"), ("—", "Dishes")])
                .ateBreathing()
                .accessibilityHidden(true)
        }
    }
}

enum AteProfileHeaderMetrics {
    static let avatar: CGFloat = 56
    static let nameBar: CGFloat = 150
    static let nameBarHeight: CGFloat = 22
    static let cityBar: CGFloat = 90
    static let cityBarHeight: CGFloat = 13
    /// `gap:18px` between the bands of You and of somebody else's page.
    static let bandGap: CGFloat = 18
}
