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
                HStack(alignment: .top, spacing: AteShareRowMetrics.scrollGap) {
                    ForEach(actions) { item($0).frame(width: AteShareRowMetrics.scrollItem) }
                }
                .padding(.horizontal, AteShareRowMetrics.scrollInset)
            }
            .scrollIndicators(.hidden)
        } else {
            HStack(alignment: .top, spacing: 0) {
                ForEach(actions) { item($0).frame(maxWidth: .infinity) }
            }
        }
    }

    /// The scrolling row's discs are a size up, as Spotify's are.
    private var discSize: CGFloat {
        actions.count > AteShareRowMetrics.fixedCount ? AteShareRowMetrics.scrollDisc : AteMetrics.hit
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
                .ateText(.shareRowLabel)
                .foregroundStyle(palette.fg)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}

/// An app's colour, on its disc in the share row. The glyph is always Ate's own Lucide icon, never
/// the app's mark.
enum AteShareBrand {
    case instagram, tiktok, messages

    var fill: AnyShapeStyle {
        switch self {
        case .instagram:
            AnyShapeStyle(RadialGradient(
                colors: AteColor.instagramColours,
                center: UnitPoint(x: 0.3, y: 1.07), startRadius: 0, endRadius: 64
            ))
        case .tiktok: AnyShapeStyle(AteColor.tiktok)
        case .messages: AnyShapeStyle(AteColor.messagesGreen)
        }
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
                Circle().fill(brand.fill)
                if isBusy {
                    AtePostingDots()
                } else {
                    icon.view(size: AteGlassDiscMetrics.glyph)
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
    static let scrollItem: CGFloat = 70
    static let scrollDisc: CGFloat = 54
    static let scrollGap: CGFloat = 4
    static let scrollInset: CGFloat = 12
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
