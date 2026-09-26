import SwiftUI

/// **A row of pills that wraps** — `display:flex; flex-wrap:wrap` as SwiftUI does not have it.
///
/// At the design's own type size every row it carries (Search's scopes, a place's facts) fits on one
/// line, and there it lays out exactly as the `HStack` it replaces: leading-aligned, `spacing` apart,
/// centred on one another. At the accessibility sizes the pills outgrow the screen, and instead of
/// truncating to "P…" or running off the edge they carry on onto the next line.
struct AteFlow: Layout {
    var spacing: CGFloat
    /// Between lines; the pills' own gap unless the markup says otherwise.
    var lineSpacing: CGFloat?

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let lines = arrange(width: proposal.width, subviews: subviews)
        let width = lines.map(\.width).max() ?? 0
        let height = lines.map(\.height).reduce(0, +) + gap * CGFloat(max(0, lines.count - 1))
        return CGSize(width: proposal.width.map { min(width, $0) } ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var top = bounds.minY
        for line in arrange(width: bounds.width, subviews: subviews) {
            var left = bounds.minX
            for item in line.items {
                subviews[item.index].place(
                    at: CGPoint(x: left, y: top + line.height / 2),
                    anchor: .leading,
                    proposal: ProposedViewSize(item.size)
                )
                left += item.size.width + spacing
            }
            top += line.height + gap
        }
    }

    private var gap: CGFloat { lineSpacing ?? spacing }

    private struct Item {
        let index: Int
        let size: CGSize
    }

    private struct Line {
        var items: [Item] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(width: CGFloat?, subviews: Subviews) -> [Line] {
        let limit = width ?? .infinity
        var lines: [Line] = []
        var line = Line()
        for index in subviews.indices {
            let ideal = subviews[index].sizeThatFits(.unspecified)
            // A pill wider than the whole row gets the row, and wraps or truncates inside itself.
            let size = ideal.width > limit
                ? subviews[index].sizeThatFits(ProposedViewSize(width: limit, height: nil))
                : ideal
            let needed = line.items.isEmpty ? size.width : line.width + spacing + size.width
            if needed > limit, line.items.isEmpty == false {
                lines.append(line)
                line = Line()
            }
            line.width = line.items.isEmpty ? size.width : line.width + spacing + size.width
            line.height = max(line.height, size.height)
            line.items.append(Item(index: index, size: size))
        }
        if line.items.isEmpty == false { lines.append(line) }
        return lines
    }
}
