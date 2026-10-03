import SwiftUI

/// **A recent search** — what Search shows before anything is typed: the mark, the words as they
/// were searched, on a 58 row ruled at the top by a hairline (except the first). A tap searches them
/// again.
struct AteRecentSearchRow: View {
    let text: String
    var isFirst = false
    let action: () -> Void

    @Environment(\.atePalette) private var palette

    var body: some View {
        Button(action: action) {
            HStack(spacing: AteDishRowMetrics.gap) {
                AteIcon.search.view(size: AteRecentSearchRowMetrics.icon)
                    .foregroundStyle(palette.muted)
                Text(text)
                    .ateText(.rowTitle)
                    .foregroundStyle(palette.fg)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: AteMetrics.rowHeight)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .overlay(alignment: .top) {
            if isFirst == false { AteHairline() }
        }
        .accessibilityLabel(text)
        .accessibilityIdentifier("search.recent")
    }
}

enum AteRecentSearchRowMetrics {
    /// `ic("clock", 20)` in the mockup; Search's own mark until the icon set carries a clock.
    static let icon: CGFloat = 20
}
