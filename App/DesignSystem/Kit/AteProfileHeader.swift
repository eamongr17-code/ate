import AteKit
import SwiftUI

/// **Your own header on You** — a 72pt avatar and the handle on ONE line that ends in an ellipsis
/// when it is long, the city muted under it, then the totals as one line (`you-header.html` A, Eamon
/// 28 Oct). The settings control is the root's toolbar disc, not part of this row.
struct AteProfileHeader: View {
    let summary: ProfileSummary

    @Environment(\.atePalette) private var palette

    var body: some View {
        HStack(spacing: AteMetrics.regular) {
            AteAvatar(
                userID: summary.userID,
                handle: summary.username,
                side: AteProfileHeaderMetrics.avatar,
                textStyle: .avatarMonogramCompact,
                url: summary.avatarURL.flatMap(URL.init(string:))
            )
            VStack(alignment: .leading, spacing: AteMetrics.hairspace) {
                Text(verbatim: "@\(summary.username)")
                    .ateText(.youHandleCompact)
                    .foregroundStyle(palette.fg)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let city = summary.city, city.isEmpty == false {
                    Text(city)
                        .ateText(.meta)
                        .foregroundStyle(palette.muted)
                        .lineLimit(1)
                }
                AteProfileCounts(summary: summary)
                    .padding(.top, AteMetrics.hairspace)
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
        .ateSkeletonSweep(breathes)
        .accessibilityHidden(true)
    }
}

/// **The totals** — "29 dishes · 16 places", the counts in ink and the words muted — under the handle
/// on You and on somebody else's page alike. Visits are not counted here (Eamon, 28 Oct).
struct AteProfileCounts: View {
    let summary: ProfileSummary

    @Environment(\.atePalette) private var palette

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: AteProfileHeaderMetrics.countsGap) {
            figure(summary.dishes)
            word(summary.dishes == 1 ? "dish" : "dishes")
            word("·")
            figure(summary.places)
            word(summary.places == 1 ? "place" : "places")
        }
        .lineLimit(1)
        .minimumScaleFactor(0.8)
        .accessibilityElement(children: .combine)
    }

    private func figure(_ value: Int) -> some View {
        Text(value.formatted())
            .ateText(.pageHeaderStrong)
            .foregroundStyle(palette.fg)
    }

    private func word(_ text: String) -> some View {
        Text(text)
            .ateText(.pageHeaderLine)
            .foregroundStyle(palette.muted)
    }
}

enum AteProfileHeaderMetrics {
    static let avatar: CGFloat = 72
    static let nameBar: CGFloat = 150
    static let nameBarHeight: CGFloat = 22
    static let cityBar: CGFloat = 130
    static let cityBarHeight: CGFloat = 13
    /// The space between a count and its word.
    static let countsGap: CGFloat = 4
    /// `gap:18px` between the bands of You and of somebody else's page.
    static let bandGap: CGFloat = 18
}
