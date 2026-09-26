import Foundation

public extension EntryComposition {
    /// **The Diet key** (prototype, round 3): puts a tag chip after the current dish.
    ///
    /// A chip belongs between a dish and its score — "tiramisu v 3.0", the one order the sorter
    /// and ``EntryBodyTokens`` read. So when the caret sits just after a score pill (only
    /// whitespace between), the chip goes in front of that pill; anywhere else it goes at the caret,
    /// which is where the dish being written ends. The caret stays after everything it was after.
    func insertingTag(_ tag: DietTag, atDisplayOffset caret: Int) -> (EntryComposition, caret: Int) {
        let token = EntryToken(kind: .tag(DietTagMark(tag: tag, text: tag.label)))
        guard let score = scoreEnding(beforeDisplayOffset: caret) else {
            return inserting(token, atDisplayOffset: caret)
        }
        let (next, _) = inserting(token, atDisplayOffset: displayOffset(forPlainOffset: score.span.location))
        let added = next.displayString.utf16.count - displayString.utf16.count
        return (next, caret: caret + added)
    }

    /// The score pill that ends just before `offset`, with nothing but spaces between.
    private func scoreEnding(beforeDisplayOffset offset: Int) -> EntryTokenSpan? {
        var plainOffset = self.plainOffset(forDisplayOffset: offset)
        let units = Array(plain.utf16)
        while plainOffset > 0, units[plainOffset - 1] == 32 { plainOffset -= 1 }
        return spans.first { $0.token.score != nil && $0.span.endLocation == plainOffset }
    }
}
