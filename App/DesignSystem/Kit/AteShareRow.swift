import SwiftUI

/// **"Share to"** — the share screen's fixed row of ways out (Strava, Beli, Spotify: a row, not a
/// system sheet, until "More"). Each is the kit's glass disc with one word under it. Instagram
/// Stories and Copy link sit first, the same size, the same tap (Eamon: equally accessible). A disc
/// that has just acted says so on itself — "Copied", "Saved" — and nothing else does (design rule 1:
/// no toast, no banner).
struct AteShareRow: View {
    struct Action: Identifiable {
        let id: String
        var icon: AteIcon
        var title: String
        /// The ink disc: the first way out.
        var isPrimary = false
        var isEnabled = true
        var isBusy = false
        let action: () -> Void
    }

    let actions: [Action]

    @Environment(\.atePalette) private var palette

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(actions) { action in
                VStack(spacing: AteShareRowMetrics.labelGap) {
                    AteGlassDisc(
                        icon: action.icon,
                        label: action.title,
                        role: action.isPrimary ? .primary : .plain,
                        isEnabled: action.isEnabled,
                        isBusy: action.isBusy,
                        identifier: "share.\(action.id)",
                        action: action.action
                    )
                    Text(action.title)
                        .ateText(.shareRowLabel)
                        .foregroundStyle(palette.fg)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity)
                .accessibilityElement(children: .combine)
            }
        }
    }
}

enum AteShareRowMetrics {
    static let labelGap: CGFloat = 6
}

extension AteTextStyle {
    /// The word under a share disc. Bricolage 500 at 11.
    static let shareRowLabel = AteTextStyle(
        voice: .display, size: 11, weight: 500, trackingEm: 0, lineHeight: 1.15, textStyle: .caption,
        maximumSize: 14
    )
}

#if DEBUG
#Preview("Share row") {
    AteShareRow(actions: [
        .init(id: "stories", icon: .camera, title: "Instagram Stories", isPrimary: true) {},
        .init(id: "link", icon: .link, title: "Copy link") {},
        .init(id: "messages", icon: .messageCircle, title: "Messages") {},
        .init(id: "save", icon: .download, title: "Save image") {},
        .init(id: "more", icon: .more, title: "More") {}
    ])
    .padding()
    .ateAccentGround(AteColor.coral)
}
#endif
