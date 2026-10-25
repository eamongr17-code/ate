import SwiftUI

/// One run of a notification's sentence: the names in it are strong, the rest plain.
enum AteNotificationRun: Equatable {
    case plain(String)
    case strong(String)
}

/// **The notification row** — every row the notifications page draws (`notifications-refined.html`,
/// approved 25 Oct, groups by kind): the sender's 36 avatar, a coral dot before it while the row is
/// new, one sentence saying what happened ("**@jessw** ate with you at **Tipo 00**") with its day or
/// count in muted after it, and under the sentence the row's answer as two pills, quiet then ink. What
/// the row is about sits at the right (the tagger's photo, the list's cover). A tap on the row opens
/// it; the pills answer it. A hairline over every row but the first.
///
/// `.nr{gap:12px; padding:13px 0; border-top:1px hair}`, `.tx{500 16px/1.3}`, `.tx b{700}`,
/// `.acts{gap:10px}` under the sentence, the unread dot 8 at `left:-13px`.
struct AteNotificationRow<Trailing: View>: View {
    let userID: UUID
    let handle: String
    var avatarURL: URL?
    let sentence: [AteNotificationRun]
    /// After the sentence, muted — "Sat 19 Sep", "12 dishes".
    var detail: String?
    var isUnread = false
    let decline: String
    let primary: String
    var isFirst = false
    var identifier = "notification.row"
    let onOpen: () -> Void
    let onDecline: () -> Void
    let onPrimary: () -> Void
    @ViewBuilder var trailing: () -> Trailing

    @Environment(\.atePalette) private var palette
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        HStack(alignment: .top, spacing: AteNotificationRowMetrics.gap) {
            VStack(alignment: .leading, spacing: AteNotificationRowMetrics.answerTop) {
                Button(action: onOpen) {
                    HStack(alignment: .top, spacing: AteNotificationRowMetrics.gap) {
                        AteAvatar(userID: userID, handle: handle, size: .review, url: avatarURL)
                            .overlay(alignment: .topLeading) { if isUnread { unreadDot } }
                        Text(line)
                            .ateText(.notificationLine)
                            .foregroundStyle(palette.fg)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, AteNotificationRowMetrics.lineTop)
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isButton)
                .accessibilityIdentifier(identifier)
                HStack(spacing: AteNotificationRowMetrics.answerGap) {
                    AteInkPill(
                        title: decline, size: .row, isQuiet: true, identifier: "\(identifier).decline",
                        action: onDecline
                    )
                    AteInkPill(title: primary, size: .row, identifier: "\(identifier).primary", action: onPrimary)
                }
                .padding(.leading, AteNotificationRowMetrics.avatar + AteNotificationRowMetrics.gap)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            trailing()
        }
        .padding(.vertical, AteNotificationRowMetrics.padding)
        .padding(.horizontal, AteMetrics.gutter)
        .background(palette.ground)
        .overlay(alignment: .top) {
            if isFirst == false { AteHairline().padding(.horizontal, AteMetrics.gutter) }
        }
    }

    /// The sentence: plain runs at 500, names at 700, the detail muted after a space.
    private var line: AttributedString {
        let plain = Font(AteFont.uiFont(for: .notificationLine, dynamicTypeSize: dynamicTypeSize))
        let strong = Font(AteFont.uiFont(for: .notificationStrong, dynamicTypeSize: dynamicTypeSize))
        var text = AttributedString()
        for run in sentence {
            switch run {
            case .plain(let words):
                var part = AttributedString(words)
                part.font = plain
                text += part
            case .strong(let words):
                var part = AttributedString(words)
                part.font = strong
                text += part
            }
        }
        if let detail {
            var part = AttributedString(" \(detail)")
            part.font = plain
            part.foregroundColor = palette.muted
            text += part
        }
        return text
    }

    /// New since the last look: coral, in the gutter, level with the avatar's upper half.
    private var unreadDot: some View {
        Circle()
            .fill(AteColor.coral)
            .frame(width: AteNotificationRowMetrics.dot, height: AteNotificationRowMetrics.dot)
            .offset(x: -AteNotificationRowMetrics.dotInset, y: AteNotificationRowMetrics.dotTop)
            .accessibilityHidden(true)
    }
}

/// The same row while the list is read: the avatar's disc, two bars, the two pills' shapes and the
/// picture's square, breathing to 45%.
struct AteNotificationRowSkeleton: View {
    var isFirst = false

    @Environment(\.atePalette) private var palette

    var body: some View {
        HStack(alignment: .top, spacing: AteNotificationRowMetrics.gap) {
            Circle()
                .fill(palette.hairline)
                .frame(width: AteNotificationRowMetrics.avatar, height: AteNotificationRowMetrics.avatar)
            VStack(alignment: .leading, spacing: AteMetrics.snug) {
                AteSkeletonBar(width: AteNotificationRowMetrics.skeletonLine, height: 14, palette: palette)
                AteSkeletonBar(width: AteNotificationRowMetrics.skeletonMeta, height: 14, palette: palette)
                HStack(spacing: AteNotificationRowMetrics.answerGap) {
                    Capsule().fill(palette.hairline)
                        .frame(width: AteNotificationRowMetrics.skeletonPill, height: AteInkPillMetrics.rowHeight)
                    Capsule().fill(palette.hairline)
                        .frame(width: AteNotificationRowMetrics.skeletonPill, height: AteInkPillMetrics.rowHeight)
                }
                .padding(.top, AteMetrics.tight)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            RoundedRectangle(cornerRadius: AteMetrics.slipCorner, style: .continuous)
                .fill(palette.hairline)
                .frame(width: AteNotificationRowMetrics.picture, height: AteNotificationRowMetrics.picture)
        }
        .padding(.vertical, AteNotificationRowMetrics.padding)
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
    /// `.nr{padding:13px 0}`.
    static let padding: CGFloat = 13
    /// The sentence's first line sits level with the avatar's middle.
    static let lineTop: CGFloat = 1
    /// `.d{gap:10px}`: sentence to pills.
    static let answerTop: CGFloat = 10
    static let answerGap: CGFloat = 10
    static let avatar: CGFloat = 36
    /// What the row is about, at the right: the dish row's 56 (``AteThumb/Size/row``).
    static let picture: CGFloat = 56
    static let dot: CGFloat = 8
    /// `left:-13px`: the dot's centre 9 from the avatar, in the gutter.
    static let dotInset: CGFloat = 13
    static let dotTop: CGFloat = 14
    static let skeletonLine: CGFloat = 176
    static let skeletonMeta: CGFloat = 112
    static let skeletonPill: CGFloat = 86
}
