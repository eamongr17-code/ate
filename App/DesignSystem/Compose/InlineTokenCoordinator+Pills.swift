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
            // Not while the slider is open on it: the panel covers the pill, and the sweep is for
            // the moment it is seen — when the panel settles away and the words re-render.
            guard span.token.id != selectedTokenID,
                  let rating = span.token.score, ScoreStyle.of(rating).shimmers,
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

extension InlineTokenEditor.Coordinator {
    /// **A dish's codes are one chip** (``DietChipJoin``), kept so as the words change under them: two
    /// codes one space apart run on into each other and the space between them closes up; anything
    /// typed between them parts them again. **Attributes only**, like ``attach(_:in:)``, so nothing
    /// UIKit has registered for undo is disturbed — and a chip is only redrawn when its join moved.
    func regroupTags(in view: InlineTokenTextView, reassertingSpaces: Bool = false) {
        let storage = view.textStorage
        let string = storage.string as NSString
        var chips: [(index: Int, token: EntryToken)] = []
        var opened: [Int] = []
        for index in 0..<storage.length {
            if storage.attribute(.ateCollapsedSpace, at: index, effectiveRange: nil) != nil { opened.append(index) }
            guard string.character(at: index) == InlineTokenAttributes.objectReplacement,
                  let box = storage.attribute(.ateToken, at: index, effectiveRange: nil) as? TokenBox,
                  box.token.tag != nil else { continue }
            chips.append((index, box.token))
        }
        let runs = InlineTokenAttributes.tagRuns(chips.map { $0.index..<($0.index + 1) }) { string.character(at: $0) }
        let closed = Set(runs.spaces)
        let stale = zip(chips, runs.joins).filter { chip, join in
            (storage.attribute(.ateChipJoin, at: chip.index, effectiveRange: nil) as? Int) != join.rawValue
        }
        let reopened = opened.filter { closed.contains($0) == false }
        let closing = reassertingSpaces ? Array(closed) : closed.filter { opened.contains($0) == false }
        guard stale.isEmpty == false || reopened.isEmpty == false || closing.isEmpty == false else { return }

        let wasRendering = isRendering
        isRendering = true
        let selection = view.selectedRange
        storage.beginEditing()
        for (chip, join) in stale {
            storage.setAttributes(
                attributes.attachmentString(for: chip.token, join: join).attributes(at: 0, effectiveRange: nil),
                range: NSRange(location: chip.index, length: 1)
            )
        }
        for index in reopened {
            storage.setAttributes(baseAttributes(), range: NSRange(location: index, length: 1))
        }
        for index in closing {
            storage.setAttributes(attributes.collapsedSpace(), range: NSRange(location: index, length: 1))
        }
        storage.endEditing()
        view.selectedRange = selection
        view.typingAttributes = baseAttributes()
        isRendering = wasRendering
    }
}
