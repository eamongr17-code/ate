import SwiftUI

/// **A place row** — Search's Places: the pin, the place and its suburb on ONE line (the place
/// truncates first, the suburb never), and the place's average as the score token at the right — an
/// empty slot when nobody scored it. 62 high, ruled at the top by a hairline except the first.
struct AtePlaceRow: View {
    let name: String
    var suburb: String?
    var score: AteScore?
    var isFirst = false
    let action: () -> Void

    @Environment(\.atePalette) private var palette
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        // At the accessibility sizes the suburb left the name no room at all: the two stack.
        let stacks = dynamicTypeSize.isAccessibilitySize
        let words = stacks
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 0))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: AtePlaceRowMetrics.suburbGap))
        Button(action: action) {
            HStack(spacing: AteDishRowMetrics.gap) {
                AteIcon.place.view(size: AtePlaceRowMetrics.icon)
                    .foregroundStyle(palette.fg)
                words {
                    Text(name)
                        .ateText(.rowTitle)
                        .foregroundStyle(palette.fg)
                        .lineLimit(stacks ? 3 : 1)
                    if let suburb {
                        Text(suburb)
                            .ateText(.meta)
                            .foregroundStyle(palette.muted)
                            .lineLimit(1)
                            .fixedSize()
                            .layoutPriority(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                AteScoreToken(score)
            }
            .frame(minHeight: AtePlaceRowMetrics.height)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
        .overlay(alignment: .top) {
            if isFirst == false { AteHairline() }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("search.place")
    }
}

enum AtePlaceRowMetrics {
    /// `min-height:62px`; the place and suburb `gap:5px`; the pin 20.
    static let height: CGFloat = 62
    static let suburbGap: CGFloat = 5
    static let icon: CGFloat = 20
}
