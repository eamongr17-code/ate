import SwiftUI

/// **"Share to"** — the share screen's fixed row of ways out (Strava, Beli, Spotify: a row, not a
/// system sheet, until "More"). Each is the kit's glass disc with one word under it. Instagram
/// Stories and Copy link sit first, the same size, the same tap (Eamon: equally accessible). A disc
/// that has just acted says so on itself — "Copied", "Saved" — and nothing else does (design rule 1:
/// no toast, no banner).
///
/// The ink sheet's scrolling row is Spotify's (4 Nov, Eamon): big flat discs, the app's mark filling
/// half of each, a larger word under it.
struct AteShareRow: View {
    struct Action: Identifiable {
        let id: String
        var icon: AteIcon
        var title: String
        /// The ink disc: the first way out.
        var isPrimary = false
        var isEnabled = true
        var isBusy = false
        /// An app's own colour on its disc (the ink share sheet, 11 Oct: Spotify's row), in place of
        /// the glass.
        var brand: AteShareBrand?
        let action: () -> Void
    }

    let actions: [Action]

    @Environment(\.atePalette) private var palette

    var body: some View {
        if actions.count > AteShareRowMetrics.fixedCount {
            // More ways out than fit: one row that scrolls off the edge, as Spotify's does.
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 0) {
                    ForEach(actions) { item($0).frame(width: AteShareRowMetrics.scrollItem) }
                }
                .padding(.horizontal, AteShareRowMetrics.scrollInset)
            }
            .scrollIndicators(.hidden)
            // A glass disc swells under a finger: past the row's edge, not cut off by it (4 Nov).
            .scrollClipDisabled()
        } else {
            HStack(alignment: .top, spacing: 0) {
                ForEach(actions) { item($0).frame(maxWidth: .infinity) }
            }
        }
    }

    private var isScrolling: Bool { actions.count > AteShareRowMetrics.fixedCount }

    /// The scrolling row's discs are a size up, as Spotify's are.
    private var discSize: CGFloat {
        isScrolling ? AteShareRowMetrics.scrollDisc : AteMetrics.hit
    }

    private func item(_ action: Action) -> some View {
        VStack(spacing: AteShareRowMetrics.labelGap) {
            if let brand = action.brand {
                AteBrandDisc(
                    icon: action.icon, label: action.title, brand: brand, isEnabled: action.isEnabled,
                    isBusy: action.isBusy, identifier: "share.\(action.id)", size: discSize, action: action.action
                )
            } else {
                AteGlassDisc(
                    icon: action.icon,
                    label: action.title,
                    role: action.isPrimary ? .primary : .plain,
                    isEnabled: action.isEnabled,
                    isBusy: action.isBusy,
                    identifier: "share.\(action.id)",
                    size: discSize,
                    action: action.action
                )
            }
            Text(action.title)
                .ateText(isScrolling ? .shareRowLabelLarge : .shareRowLabel)
                .foregroundStyle(palette.fg)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}

/// **A disc in an app's colour** — the share row's Stories, TikTok and Messages on the ink sheet.
/// The same size and tap as ``AteGlassDisc``; white glyph.
struct AteBrandDisc: View {
    let icon: AteIcon
    let label: String
    let brand: AteShareBrand
    var isEnabled = true
    var isBusy = false
    var identifier: String?
    var size: CGFloat = AteMetrics.hit
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().fill(brand.fill(size: size))
                if isBusy {
                    AtePostingDots()
                } else {
                    // Half the disc, as Spotify's marks are: 22 on the 44 row.
                    icon.view(size: size / 2)
                }
            }
            .foregroundStyle(AteColor.onBrand)
            .frame(width: size, height: size)
            .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .disabled(isEnabled == false || isBusy)
        .opacity(isEnabled ? 1 : AteKitColor.disabledOpacity)
        .accessibilityLabel(label)
        .accessibilityValue(isBusy ? "In progress" : "")
        .accessibilityIdentifier(identifier ?? "share.\(label.lowercased())")
    }
}

enum AteShareRowMetrics {
    static let labelGap: CGFloat = 6
    /// Up to this many share the width; more scroll.
    static let fixedCount = 5
    static let scrollItem: CGFloat = 80
    static let scrollDisc: CGFloat = 60
    static let scrollInset: CGFloat = 8
}

extension AteTextStyle {
    /// The word under a share disc. DM Sans 500 at 11.
    static let shareRowLabel = AteTextStyle(
        voice: .display, size: 11, weight: 500, trackingEm: 0, lineHeight: 1.15, textStyle: .caption,
        maximumSize: 14
    )
    /// The word under a disc in the ink sheet's scrolling row: Spotify's, a size up. DM Sans 400 at 13.
    static let shareRowLabelLarge = AteTextStyle(
        voice: .display, size: 13, weight: 400, trackingEm: 0, lineHeight: 1.15, textStyle: .caption,
        maximumSize: 16
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

#Preview("Ink sheet row") {
    AteShareRow(actions: [
        .init(id: "link", icon: .link, title: "Copy link", brand: .neutral) {},
        .init(id: "stories", icon: .instagram, title: "Stories", brand: .instagram) {},
        .init(id: "messages", icon: .messageCircle, title: "Messages", brand: .messages) {},
        .init(id: "whatsapp", icon: .whatsapp, title: "WhatsApp", brand: .whatsapp) {},
        .init(id: "tiktok", icon: .tiktok, title: "TikTok", brand: .tiktok) {},
        .init(id: "instagram", icon: .instagram, title: "Instagram", brand: .instagram) {},
        .init(id: "save", icon: .download, title: "Save", brand: .neutral) {},
        .init(id: "more", icon: .more, title: "More", brand: .neutral) {}
    ])
    .environment(\.atePalette, .ink)
    .background(AteColor.ink)
}
#endif
