import AteKit
import SwiftUI
import UIKit

/// The coordinator's round-4 pieces, kept apart for length: the one-shot sweep over a special score
/// pill, and the full stop that takes a pill's trailing space.
extension InlineTokenEditor.Coordinator {

    /// `ScoreStyle.shimmers` (round 4 exploration B and C): a perfect 5.0 or a 6 gets one sweep of
    /// light the first time it appears. The pill is an attachment, so the light is laid over its
    /// rect in the text view once layout has placed it.
    func sweepSpecialPills(_ spans: [EntryTokenSpan], in view: InlineTokenTextView) {
        for span in spans {
            guard let rating = span.token.score, ScoreStyle.of(rating).shimmers,
                  sweptPills.insert("\(span.token.id)-\(rating.halfSteps)").inserted else { continue }
            let tokenID = span.token.id
            DispatchQueue.main.async { [weak view] in
                MainActor.assumeIsolated {
                    guard let view, let rect = Self.pillRect(of: tokenID, in: view) else { return }
                    AteShimmer.sweep(over: rect, in: view)
                }
            }
        }
    }

    /// Where a token's pill is drawn in the text view: its character's rect, narrowed to the
    /// attachment's own height and sat on the baseline of its line, where the attachment sits.
    private static func pillRect(of tokenID: UUID, in view: InlineTokenTextView) -> CGRect? {
        let storage = view.textStorage
        var found: (NSRange, NSTextAttachment)?
        storage.enumerateAttribute(.ateToken, in: NSRange(0..<storage.length)) { value, range, stop in
            guard (value as? TokenBox)?.token.id == tokenID,
                  let attachment = storage.attribute(.attachment, at: range.location, effectiveRange: nil)
                    as? NSTextAttachment else { return }
            found = (range, attachment)
            stop.pointee = true
        }
        guard let (range, attachment) = found, let textRange = view.textRange(for: range) else { return nil }
        view.layoutIfNeeded()
        let line = view.firstRect(for: textRange)
        guard line.isNull == false, line.isInfinite == false else { return nil }
        let size = attachment.bounds.size
        let baseline = view.baselineY(near: line)
        return CGRect(
            x: line.minX, y: baseline - size.height - attachment.bounds.minY,
            width: size.width, height: size.height
        )
    }

    /// **No space between a pill and the punctuation after it** (round 4). A pill brings its own
    /// trailing space (``EntryComposition/inserting(_:atDisplayOffset:)``), so a full stop typed
    /// straight after the Score key used to land as "★4.5 ." — the stop takes that space's place
    /// instead, through the text view's own edit path so undo stays one coherent step.
    func textView(
        _ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String
    ) -> Bool {
        guard isRendering == false, range.length == 0, range.location >= 2,
              text.count == 1, Self.closingPunctuation.contains(text),
              let view = textView as? InlineTokenTextView else { return true }
        let string = view.textStorage.string as NSString
        guard range.location <= string.length,
              string.character(at: range.location - 1) == 32,
              string.character(at: range.location - 2) == InlineTokenAttributes.objectReplacement,
              let space = view.textRange(for: NSRange(location: range.location - 1, length: 1)) else { return true }
        view.typingAttributes = baseAttributes()
        view.replace(space, withText: text)
        return false
    }

    static let closingPunctuation: Set<String> = [".", ",", "!", "?", ";", ":", ")"]

    // MARK: UIGestureRecognizerDelegate

    /// Never take the tap away from the text view's own interaction — caret placement, selection
    /// handles and the loupe are all native behaviour we are not in the business of replacing.
    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
    ) -> Bool {
        true
    }
}
