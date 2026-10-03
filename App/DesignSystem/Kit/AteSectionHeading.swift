import SwiftUI

/// **A section's heading** — the Feed edition's `.sec`: the section's name in Bricolage 800 at 28,
/// and, on a shelf, See all with its chevron at the right, muted, on the same baseline. No eyebrow
/// above it, no rule under it.
struct AteSectionHeading: View {
    let title: String
    var onSeeAll: (() -> Void)?
    var identifier = "section"

    @Environment(\.atePalette) private var palette

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: AteSectionHeadingMetrics.gap) {
            Text(title)
                .ateText(.feedSection)
                .foregroundStyle(palette.fg)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier(identifier)
            if let onSeeAll {
                Button(action: onSeeAll) {
                    HStack(spacing: AteSectionHeadingMetrics.chevronGap) {
                        Text("See all").ateText(.feedControl)
                        AteIcon.chevron.view(size: AteSectionHeadingMetrics.chevron)
                    }
                    .foregroundStyle(palette.muted)
                    .frame(minHeight: AteMetrics.hit)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("\(identifier).seeAll")
            }
        }
        .padding(.horizontal, AteMetrics.gutter)
        .padding(.top, AteSectionHeadingMetrics.top)
        .padding(.bottom, AteSectionHeadingMetrics.bottom)
    }
}

enum AteSectionHeadingMetrics {
    /// A section opens 34 under the last one and sits 14 over its content (`padding:34px 20px 14px`).
    static let top: CGFloat = 34
    static let bottom: CGFloat = 14
    /// The first section, under the header: 8.
    static let firstTop: CGFloat = 8
    static let gap: CGFloat = 10
    static let chevronGap: CGFloat = 2
    static let chevron: CGFloat = 16
}
