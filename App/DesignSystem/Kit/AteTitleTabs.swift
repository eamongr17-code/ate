import SwiftUI

/// **Titles as tabs** (`journal-header.html` B, 24 Oct) — a root titled by its choices: each one a
/// root title in Young Serif, side by side on the header's one row, the one showing in ink and the
/// rest dimmed. A tap on a dimmed title shows it. The Journal's "Journal  Lists"; no pill, no
/// segmented control (Linear's Issues / Projects, Apple Music's Library).
struct AteTitleTabs<Value: Hashable>: View {
    let options: [AteSegment<Value>]
    @Binding var selection: Value
    /// Each title's identifier is this, a dot, and its title in lower case.
    var identifier: String?

    @Environment(\.atePalette) private var palette

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: AteTitleTabsMetrics.spacing) {
            ForEach(options) { option in
                let isCurrent = option.value == selection
                Button {
                    guard isCurrent == false else { return }
                    AteHaptics.key()
                    selection = option.value
                } label: {
                    Text(option.title)
                        .ateText(.kitRootTitle)
                        .foregroundStyle(palette.fg)
                        .opacity(isCurrent ? 1 : AteTitleTabsMetrics.dimmed)
                        .lineLimit(1)
                        .fixedSize()
                        .frame(minHeight: AteMetrics.hit)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isCurrent ? [.isButton, .isSelected, .isHeader] : .isButton)
                .accessibilityIdentifier(identifier.map { "\($0).\(option.title.lowercased())" } ?? option.title)
            }
        }
        .animation(AteTitleTabsMetrics.swap, value: selection)
        // Two titles and the glass group share one row: past this size they would push it off.
        .dynamicTypeSize(...AteTitleTabsMetrics.largestType)
    }
}

enum AteTitleTabsMetrics {
    /// Between two titles: a word space at the title's size.
    static let spacing: CGFloat = 14
    /// A title not showing: the ink, dimmed, so it reads as the same title in waiting.
    static let dimmed: Double = 0.32
    /// The ink moving from one title to the other.
    static let swap: Animation = .easeOut(duration: 0.15)
    static let largestType: DynamicTypeSize = .xLarge
}
