import SwiftUI

/// **The quiet row at the end of a finite page** — the edition's `.endrow` (`discover.html`): a line
/// icon, a name, a muted count, a muted chevron, between two hairlines. The one door to a list the page
/// only points at (What you follow). Not a call to action: no fill, no pill.
///
/// `.endrow{gap:12px; margin:28px 20px 0; min-height:56px; border-top/bottom:1px hair}`; the icon 20,
/// the chevron 18; `.c{margin-left:auto}`.
struct AteEndLinkRow: View {
    var icon: AteIcon?
    let title: String
    var count: Int?
    var identifier: String?
    let action: () -> Void

    @Environment(\.atePalette) private var palette

    var body: some View {
        Button(action: action) {
            HStack(spacing: AteEndLinkRowMetrics.gap) {
                if let icon {
                    icon.view(size: AteEndLinkRowMetrics.icon)
                        .foregroundStyle(palette.fg)
                }
                Text(title)
                    .ateText(.kitEndRow)
                    .foregroundStyle(palette.fg)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if let count {
                    Text(verbatim: "\(count)")
                        .ateText(.kitEndRowCount)
                        .monospacedDigit()
                        .foregroundStyle(palette.muted)
                }
                AteIcon.chevron.view(size: AteEndLinkRowMetrics.chevron)
                    .foregroundStyle(palette.muted)
            }
            .frame(minHeight: AteEndLinkRowMetrics.height)
            .overlay(alignment: .top) { AteHairline() }
            .overlay(alignment: .bottom) { AteHairline() }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, AteMetrics.gutter)
        .padding(.top, AteEndLinkRowMetrics.top)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(count.map { "\($0)" } ?? "")
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier(identifier ?? "endLink")
    }
}

enum AteEndLinkRowMetrics {
    static let gap: CGFloat = 12
    static let top: CGFloat = 28
    static let height: CGFloat = 56
    static let icon: CGFloat = 20
    static let chevron: CGFloat = 18
    /// The end line after it sits `padding-top:34px` below, not the rule's own 40.
    static let endRuleTop: CGFloat = 34
}
