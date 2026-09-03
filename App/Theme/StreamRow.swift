import SwiftUI

/// **The one divider rule** (design-language §1.2).
///
/// A hairline is ONE DEVICE PIXEL of `separator`, drawn edge to edge, and it appears only between
/// siblings on a plane. Never `Divider()`: that is one *logical* point, which at 3× is three
/// physical pixels — the difference between a stream that reads as one continuous thing and a list
/// that reads as a spreadsheet.
///
/// Divider XOR container, always: if a row draws a fill and a radius, it must not also be parted by
/// a rule, and vice versa. Groups (`.insetGrouped`) keep the system's own separators and are not
/// this component's business.
struct StreamDivider: View {
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        Theme.Color.separator
            .frame(height: Theme.Size.hairline(displayScale: displayScale))
            .accessibilityHidden(true)
    }
}

extension View {
    /// One row of a **plane**: content directly on `background`, gutter margins, `streamRow` padding
    /// top and bottom, and a full-bleed hairline drawn at its bottom edge.
    ///
    /// The insets are applied by this modifier rather than by `listRowInsets`, and the row is then
    /// given zero insets — that is what lets the hairline reach the screen edges while the text
    /// column still sits at the gutter. The system separator is hidden because this row draws its
    /// own; drawing both is how a list gets two rules of different weights and inset.
    ///
    /// - Parameter showsDivider: `false` for the last row of a stream and for the row *before* a
    ///   section header, where a rule would part a thing from a heading rather than from a sibling.
    /// - Parameter dividerLeadingInset: the one exception in the app (§1.2): inside a diary sitting
    ///   block the rule between two dishes of the same visit is inset to the text column, so the
    ///   block reads as one meal. Everywhere else this is zero.
    func streamRow(showsDivider: Bool = true, dividerLeadingInset: CGFloat = 0) -> some View {
        self
            .padding(.horizontal, Theme.Spacing.gutter)
            .padding(.vertical, Theme.Spacing.streamRow)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .bottom) {
                if showsDivider {
                    StreamDivider()
                        .padding(.leading, dividerLeadingInset)
                }
            }
            .listRowInsets(EdgeInsets())
            .listRowSeparator(.hidden)
            .listRowBackground(Theme.Color.background)
    }
}

#Preview("Stream rows") {
    List {
        ForEach(0..<4, id: \.self) { index in
            VStack(alignment: .leading, spacing: Theme.Spacing.tight) {
                Text("Row \(index)").font(Theme.Text.itemTitle)
                Text("A second line of the same thought").font(Theme.Text.detail)
                    .foregroundStyle(Theme.Color.textSecondary)
            }
            .streamRow(showsDivider: index < 3)
        }
    }
    .listStyle(.plain)
    .background(Theme.Color.background)
}
