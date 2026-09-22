import Foundation

/// How a multi-dish receipt's media band is divided (design-language §4).
///
/// The receipt is a fixed 4:5 canvas, so "how many pictures" cannot be answered by letting a stack
/// grow — every count has to resolve to ONE composition. The rule is deterministic and lives here
/// rather than in the view because "what does a five-dish sitting look like" is a question with a
/// right answer that must not change between the on-screen artifact and the exported image.
public enum ReceiptMosaic {

    /// The compositions. There are four, and there is no fifth: past four dishes the band stops
    /// adding cells and starts counting.
    public enum Layout: Sendable, Hashable {
        /// One cell filling the band. Also the answer for an empty receipt — the band is never blank.
        case single
        /// Two cells, split down the middle.
        case sideBySide
        /// One large cell on the left, two stacked on the right.
        case oneLargeTwoStacked
        /// A 2×2 grid. `overflow` is how many dishes didn't get a cell — rendered as "+n" on the
        /// last one, never dropped silently.
        case grid(overflow: Int)
    }

    public static func layout(forItemCount count: Int) -> Layout {
        switch count {
        case ..<2: .single
        case 2: .sideBySide
        case 3: .oneLargeTwoStacked
        default: .grid(overflow: count - 4)
        }
    }

    /// How many dishes the layout actually draws — the prefix the band renders.
    public static func visibleCount(for layout: Layout) -> Int {
        switch layout {
        case .single: 1
        case .sideBySide: 2
        case .oneLargeTwoStacked: 3
        case .grid: 4
        }
    }

    /// The "+n" badge on the last cell of a full grid, or `nil` when nothing is hidden.
    public static func overflowBadge(for layout: Layout) -> String? {
        guard case .grid(let overflow) = layout, overflow > 0 else { return nil }
        return "+\(overflow)"
    }
}
