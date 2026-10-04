import SwiftUI

/// **The ask card** — the Feed's one-time "What do you crave?" (`discover.html`, option C): a white
/// card in the edition with its question, a row of toggle pills, and a small glass close disc in its
/// top-right corner. No helper copy. Folding it away is the screen's job (it removes the card).
///
/// `.ask{margin:0 16px; background:#fff; border-radius:16px; padding:18px 18px 20px; gap:16px}`;
/// `.ask .x{right:12px; top:12px; width:36px; height:36px}`; the question `padding-right:44px`.
struct AteAskCard<Pills: View>: View {
    let title: String
    let closeLabel: String
    var closeIdentifier: String?
    let onClose: () -> Void
    @ViewBuilder var pills: Pills

    var body: some View {
        VStack(alignment: .leading, spacing: AteAskCardMetrics.gap) {
            Text(title)
                .ateText(.kitAskTitle)
                .foregroundStyle(AteAskCardMetrics.palette.fg)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.trailing, AteAskCardMetrics.titleTrailing)
                .accessibilityAddTraits(.isHeader)
            AteTogglePillFlow { pills }
        }
        .padding(.top, AteAskCardMetrics.paddingTop)
        .padding(.horizontal, AteAskCardMetrics.paddingSide)
        .padding(.bottom, AteAskCardMetrics.paddingBottom)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AteColor.slip, in: RoundedRectangle(cornerRadius: AteAskCardMetrics.radius, style: .continuous))
        .overlay(alignment: .topTrailing) {
            AteSmallGlassDisc(icon: .close, label: closeLabel, identifier: closeIdentifier, action: onClose)
                .padding(.top, AteAskCardMetrics.closeInset)
                .padding(.trailing, AteAskCardMetrics.closeInset)
        }
        .environment(\.atePalette, AteAskCardMetrics.palette)
        .accessibilityElement(children: .contain)
    }
}

/// **A small glass disc** — a 36pt disc of the system's Liquid Glass with an 18pt glyph, for a close
/// inside a card (the ask card's `.x`). The 44pt hit area is kept around it.
struct AteSmallGlassDisc: View {
    let icon: AteIcon
    let label: String
    var identifier: String?
    let action: () -> Void

    @Environment(\.atePalette) private var palette

    var body: some View {
        Button(action: action) {
            icon.view(size: AteAskCardMetrics.closeGlyph)
                .foregroundStyle(palette.fg)
                .frame(width: AteAskCardMetrics.closeDisc, height: AteAskCardMetrics.closeDisc)
                .glassEffect(.regular.interactive(), in: .circle)
                .padding(AteAskCardMetrics.closeHitOutset)
                .contentShape(.rect)
                .padding(-AteAskCardMetrics.closeHitOutset)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityIdentifier(identifier ?? "glass.\(label.lowercased())")
    }
}

enum AteAskCardMetrics {
    static let radius: CGFloat = 16
    static let gap: CGFloat = 16
    static let paddingTop: CGFloat = 18
    static let paddingSide: CGFloat = 18
    static let paddingBottom: CGFloat = 20
    /// The card's own inset from the screen edge: `margin:0 16px`.
    static let margin: CGFloat = AteMetrics.loose
    static let titleTrailing: CGFloat = 44
    static let closeInset: CGFloat = 12
    static let closeDisc: CGFloat = 36
    static let closeGlyph: CGFloat = 18
    static let closeHitOutset: CGFloat = (AteMetrics.hit - closeDisc) / 2
    static let palette = AtePalette.askCard
}
