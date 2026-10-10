import SwiftUI

/// **The notification row** — the one row the notifications page draws (`ate-with.html`, `.pr`): the
/// sender's 36 avatar, one line saying what happened, where and when under it in meta, and a 36 glass
/// X at the right. A tap on the row opens it; the X only clears it. A hairline over every row but the
/// first.
///
/// `.pr{gap:12px; min-height:62px; border-top:1px hair}`, `.pr .d b{600 17px/1.2, -0.01em, one line}`,
/// `.meta{500 13px/1.3, muted}`, the X `width:36px; height:36px`, its glyph 16.
struct AteNotificationRow: View {
    let userID: UUID
    let handle: String
    /// What happened — "@jessw ate with you". One line, truncating.
    let line: String
    /// Where and when — "Tipo 00, Sat 19 Sep".
    var meta: String?
    var isFirst = false
    var identifier = "notification.row"
    let onOpen: () -> Void
    let onClear: () -> Void

    @Environment(\.atePalette) private var palette

    var body: some View {
        HStack(spacing: AteNotificationRowMetrics.gap) {
            Button(action: onOpen) {
                HStack(spacing: AteNotificationRowMetrics.gap) {
                    AteAvatar(userID: userID, handle: handle, size: .review)
                    VStack(alignment: .leading, spacing: AteNotificationRowMetrics.lineGap) {
                        Text(line)
                            .ateText(.rowTitle)
                            .foregroundStyle(palette.fg)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        if let meta {
                            Text(meta)
                                .ateText(.meta)
                                .foregroundStyle(palette.muted)
                                .lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(minHeight: AteNotificationRowMetrics.height)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityIdentifier(identifier)
            AteNotificationClear(action: onClear)
        }
        .padding(.horizontal, AteMetrics.gutter)
        .background(palette.ground)
        .overlay(alignment: .top) {
            if isFirst == false { AteHairline().padding(.horizontal, AteMetrics.gutter) }
        }
    }
}

/// The row's X: the glass disc's anatomy at the row's 36, its glyph at 16.
private struct AteNotificationClear: View {
    let action: () -> Void

    @Environment(\.atePalette) private var palette

    var body: some View {
        Button(action: action) {
            AteIcon.close.view(size: AteNotificationRowMetrics.clearGlyph)
                .foregroundStyle(palette.fg)
                .frame(width: AteNotificationRowMetrics.clear, height: AteNotificationRowMetrics.clear)
                .glassEffect(.regular.interactive(), in: .circle)
                .ateHitArea(AteNotificationRowMetrics.clearOutset)
        }
        .buttonStyle(.plain)
        .ateHitFootprint(AteNotificationRowMetrics.clearOutset)
        .accessibilityLabel("Clear")
        .accessibilityIdentifier("notification.clear")
    }
}

/// The same row while the list is read: the avatar's disc and two bars, breathing to 45%.
struct AteNotificationRowSkeleton: View {
    var isFirst = false

    @Environment(\.atePalette) private var palette

    var body: some View {
        HStack(spacing: AteNotificationRowMetrics.gap) {
            Circle()
                .fill(palette.hairline)
                .frame(width: AteNotificationRowMetrics.avatar, height: AteNotificationRowMetrics.avatar)
            VStack(alignment: .leading, spacing: AteMetrics.snug) {
                AteSkeletonBar(width: AteNotificationRowMetrics.skeletonLine, height: 14, palette: palette)
                AteSkeletonBar(width: AteNotificationRowMetrics.skeletonMeta, height: 11, palette: palette)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Circle()
                .fill(palette.hairline)
                .frame(width: AteNotificationRowMetrics.clear, height: AteNotificationRowMetrics.clear)
        }
        .frame(minHeight: AteNotificationRowMetrics.height)
        .padding(.horizontal, AteMetrics.gutter)
        .overlay(alignment: .top) {
            if isFirst == false { AteHairline().padding(.horizontal, AteMetrics.gutter) }
        }
        .ateSkeletonSweep()
        .accessibilityHidden(true)
    }
}

enum AteNotificationRowMetrics {
    static let gap: CGFloat = 12
    static let height: CGFloat = 62
    /// `.d{gap:1px}`.
    static let lineGap: CGFloat = 1
    static let avatar: CGFloat = 36
    static let clear: CGFloat = 36
    static let clearGlyph: CGFloat = 16
    /// The 36 disc answers a 44 finger.
    static let clearOutset = AteHitOutset(width: clear, height: clear)
    static let skeletonLine: CGFloat = 176
    static let skeletonMeta: CGFloat = 112
}
