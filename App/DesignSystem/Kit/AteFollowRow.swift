import SwiftUI

/// **A followed category's row** — What you follow's `.fr` (`discover.html`): the category's #1 dish
/// as its thumbnail, the category's name, a chevron; a hairline over every row but the first. A tap
/// opens the category; the list around it supplies the swipe (Unfollow) and the drag (reorder).
///
/// `.fr{gap:12px; min-height:72px; padding:0 20px; border-top:1px hair; background:ground}`;
/// `.fr:first-child{border-top:0}`; the chevron 18.
struct AteFollowRow: View {
    let photo: AtePhoto
    let name: String
    var isFirst = false
    var identifier: String?
    let onOpen: () -> Void

    @Environment(\.atePalette) private var palette

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: AteFollowRowMetrics.gap) {
                AteThumb(photo: photo, size: .row)
                Text(name)
                    .ateText(.kitFollowName)
                    .foregroundStyle(palette.fg)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                AteIcon.chevron.view(size: AteFollowRowMetrics.chevron)
                    .foregroundStyle(palette.fg)
            }
            .padding(.horizontal, AteMetrics.gutter)
            .frame(minHeight: AteFollowRowMetrics.height)
            .background(palette.ground)
            .overlay(alignment: .top) {
                if isFirst == false { AteHairline() }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(name)
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier(identifier ?? "follow.row")
    }
}

/// The same row while the list is read: the thumbnail's slot and one bar, breathing.
struct AteFollowRowSkeleton: View {
    var isFirst = false

    @Environment(\.atePalette) private var palette

    var body: some View {
        HStack(spacing: AteFollowRowMetrics.gap) {
            RoundedRectangle(cornerRadius: AteThumbMetrics(.row).radius, style: .continuous)
                .fill(palette.hairline)
                .frame(width: AteThumbMetrics(.row).width, height: AteThumbMetrics(.row).height)
            AteSkeletonBar(width: AteFollowRowMetrics.skeletonBar, height: AteFollowRowMetrics.skeletonBarHeight,
                           palette: palette)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, AteMetrics.gutter)
        .frame(minHeight: AteFollowRowMetrics.height)
        .overlay(alignment: .top) {
            if isFirst == false { AteHairline() }
        }
        .ateSkeletonSweep()
        .accessibilityHidden(true)
    }
}

enum AteFollowRowMetrics {
    static let gap: CGFloat = 12
    static let height: CGFloat = 72
    static let chevron: CGFloat = 18
    static let skeletonBar: CGFloat = 132
    static let skeletonBarHeight: CGFloat = 18
}
