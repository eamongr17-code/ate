import AteKit

/// **The pills behind documents the editor has written.**
///
/// UIKit's undo and redo restore *plain* text: a document that held pills comes back holding bare
/// object-replacement characters with no token behind them. Keyed by the display string itself, so when
/// undo or redo lands the text view back on one it has held before, the pills that were in it can be
/// put back — which is what makes redoing a dictation bring its score pills back rather than deleting
/// their placeholders.
///
/// Bounded: it only has to reach as far back as somebody will plausibly undo.
struct RenderedTokenHistory {
    private var tokens: [String: [EntryTokenSpan]] = [:]
    private var order: [String] = []
    static let depth = 32

    mutating func remember(_ composition: EntryComposition, as displayString: String) {
        guard composition.spans.isEmpty == false else { return }
        if tokens[displayString] == nil { order.append(displayString) }
        tokens[displayString] = composition.displaySpans
        while order.count > Self.depth {
            tokens[order.removeFirst()] = nil
        }
    }

    func tokens(for displayString: String) -> [EntryTokenSpan]? {
        tokens[displayString]
    }
}
