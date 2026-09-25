import AteKit
import SwiftUI
import UIKit

/// ``InlineTokenEditor``'s coordinator — the whole UIKit side of the composer's editor: deriving the
/// model back out of text storage, the one path that writes into it, the token hit test, and the
/// promotion of a number the person typed.
///
/// In its own file because it is the part with the teeth, and because an editor, its text view and
/// its coordinator are three things to read rather than one to scroll.
extension InlineTokenEditor {

    @MainActor
    final class Coordinator: NSObject, UITextViewDelegate, UIGestureRecognizerDelegate {
        private var binding: Binding<EntryComposition>
        private var typography: Typography
        private var callbacks: Callbacks

        weak var textView: InlineTokenTextView?
        private var renderedRevision = -1
        private var renderedTypography: Typography?
        /// Set while we are writing the storage ourselves, so the derive-back pass stays quiet.
        private var isRendering = false
        private var servedFocusRequest = 0
        private var servedUndoRequest = 0
        private var servedRedoRequest = 0
        /// One promotion check per runloop turn, however many changes landed in it.
        private var hasPendingPromotion = false
        /// The promotion the last change made available, noticed while that change was still the
        /// present tense. See ``scheduleScorePromotion(in:)``.
        private var noticedPromotion: Promotion?
        /// The last token this editor promoted, kept so a *redo* of that promotion can put the pill
        /// back rather than leaving a bare placeholder for ``normaliseTokens(in:)`` to delete.
        private var lastPromotedToken: EntryToken?
        /// Every document this editor has written, so undo or redo landing back on one gets its pills.
        private var rendered = RenderedTokenHistory()

        private var style: AteTextStyle { typography.style }
        private var palette: AtePalette { typography.palette }
        private var dynamicTypeSize: DynamicTypeSize { typography.dynamicTypeSize }
        private var displayScale: CGFloat { typography.displayScale }
        private var colorScheme: ColorScheme { typography.colorScheme }

        init(binding: Binding<EntryComposition>, typography: Typography, callbacks: Callbacks) {
            self.binding = binding
            self.typography = typography
            self.callbacks = callbacks
        }

        func update(binding: Binding<EntryComposition>, typography: Typography, callbacks: Callbacks) {
            self.binding = binding
            self.typography = typography
            self.callbacks = callbacks
        }

        func shouldRender(revision: Int, style: AteTextStyle, dynamicTypeSize: DynamicTypeSize) -> Bool {
            renderedRevision != revision || renderedTypography != typography
        }

        // MARK: Model → storage

        /// **Every character this editor writes goes in through the text view's own edit path.**
        ///
        /// UIKit's `_UITextUndoOperationTyping` describes an edit in terms of the storage it was made
        /// against. Writing `textStorage` directly — which a wholesale `attributedText =` and the old
        /// promotion both did — leaves operations that *crash* when they run:
        /// `-[_UITextUndoOperationTyping _undoRedo]` → `NSTextStorage coordinateEditing:`. Two taps of
        /// Cmd+Z after a score promoted did exactly that, and a shake or a three-finger swipe reach
        /// the same operation.
        ///
        /// The fix is to stop going around undo rather than to fight it. `replace(_:withText:)` is the
        /// text view's own edit, so UIKit registers a coherent operation and typing undo keeps
        /// working untouched. It carries only **plain** text, which turns out to be exactly enough: a
        /// token is one object-replacement character, so the *character* goes in through the edit path
        /// and the attachment is applied afterwards as an **attribute**. Attribute edits move nothing,
        /// so they cannot invalidate an operation UIKit has already registered.
        ///
        /// One such edit: the plain text going in, where it goes, and the tokens to attach after.
        struct StorageEdit {
            var text: String
            var range: NSRange
            var tokens: [EntryTokenSpan]
            var caret: Int?
            /// False when the host already holds this composition (a render), true when the edit
            /// originated here (a promotion) and the host has to be told.
            var updatesBinding: Bool
            /// A render re-asserts the words' attributes over the **whole** document, not just the run
            /// it wrote — the typography may be what changed. Attributes only, so it disturbs nothing
            /// UIKit has registered for undo.
            var restylesAll = false
        }

        private func write(_ edit: StorageEdit, in view: InlineTokenTextView) {
            let beforeCaret = view.selectedRange.location
            isRendering = true

            let isNoOp = edit.range.length == 0 && edit.text.isEmpty
            if isNoOp {
                // Nothing to write (a re-score, a palette change): only the attributes below move.
            } else if let textRange = view.textRange(for: edit.range) {
                // `replace(_:withText:)` inserts PLAIN text under whatever the view's typing
                // attributes are. Setting them afterwards is one render too late: a draft restored
                // into a view that is already on screen came in as the system's Helvetica instead
                // of Newsreader, and the composer was the one screen in the app not in the app's
                // own voice. Set them first, then re-assert them over what landed.
                view.typingAttributes = baseAttributes()
                view.replace(textRange, withText: edit.text)
                let written = NSRange(location: edit.range.location, length: (edit.text as NSString).length)
                if written.upperBound <= view.textStorage.length {
                    view.textStorage.addAttributes(baseAttributes(), range: written)
                }
            } else {
                // No addressable document yet — the very first render, before the view is in a
                // window. There is no undo stack to keep coherent at that point either.
                view.textStorage.setAttributedString(
                    NSAttributedString(string: edit.text, attributes: baseAttributes())
                )
            }
            if edit.restylesAll, view.textStorage.length > 0 {
                view.textStorage.addAttributes(baseAttributes(), range: NSRange(0..<view.textStorage.length))
            }
            attach(edit.tokens, in: view)
            rendered.remember(composition(from: view), as: view.textStorage.string)

            let length = view.textStorage.length
            let caret = min(max(0, edit.caret ?? beforeCaret), length)
            view.selectedRange = NSRange(location: caret, length: 0)
            view.typingAttributes = baseAttributes()
            view.placeholderLabel.isHidden = length > 0
            isRendering = false

            if edit.updatesBinding {
                binding.wrappedValue = composition(from: view)
            }
            // `textViewDidChangeSelection` is suppressed while rendering, so the host would never
            // hear where the caret landed — and the NEXT token would be inserted at the stale offset
            // (the caret readout stuck at 0 after inserting one). Report it explicitly.
            callbacks.onCaretChange(view.selectedRange.location)
        }

        /// Binds each placeholder character to the token it stands for. **Attributes only**: the
        /// string is untouched, so nothing UIKit has registered for undo is disturbed.
        private func attach(_ spans: [EntryTokenSpan], in view: InlineTokenTextView) {
            guard spans.isEmpty == false else { return }
            let storage = view.textStorage
            storage.beginEditing()
            for span in spans {
                let range = NSRange(location: span.span.location, length: 1)
                guard range.upperBound <= storage.length else { continue }
                storage.setAttributes(
                    attachmentString(for: span.token).attributes(at: 0, effectiveRange: nil),
                    range: range
                )
            }
            storage.endEditing()
        }

        /// Writes a composition into the text view, putting the caret where the host asked for it — or
        /// leaving it where it was, if the host had no opinion.
        ///
        /// A re-render the host did not ask for — the palette moved, the reader changed text size, a
        /// pill became the one the slider is open on — must never move the caret. `caretAfterRender`
        /// belongs to the model change that set it, and the host keeps holding it afterwards; obeying
        /// it a second time drops the person back where they were several words ago, and the rest of
        /// what they type lands inside their own sentence.
        ///
        /// **Only what changed is written** (``DisplayEdit``): a whole-document replace made undo of a
        /// dictation bring every *other* pill back as an orphaned placeholder, which was then deleted.
        func render(_ composition: EntryComposition, revision: Int, caret: Int?, into view: InlineTokenTextView) {
            let isNewComposition = revision != renderedRevision
            let edit = DisplayEdit.between(view.textStorage.string, composition.displayString)
            write(StorageEdit(
                text: edit.replacement,
                range: edit.span.nsRange,
                tokens: composition.displaySpans,
                caret: isNewComposition ? caret : nil,
                updatesBinding: false,
                restylesAll: true
            ), in: view)
            renderedRevision = revision
            renderedTypography = typography
        }

        /// Runs the text view's own undo or redo. The whole point is that these are UIKit's
        /// operations, not ours: if a programmatic edit has left one describing storage that no
        /// longer exists, this is where it takes the app down.
        func runUndoIfRequested(undo: Int, redo: Int, in view: InlineTokenTextView) {
            // `undoManager` is the text view's own only while it is first responder; off the
            // responder chain it resolves to somebody else's.
            let wantsUndo = undo != servedUndoRequest && undo > 0
            let wantsRedo = redo != servedRedoRequest && redo > 0
            if wantsUndo || wantsRedo, view.isFirstResponder == false {
                view.becomeFirstResponder()
            }
            if undo != servedUndoRequest {
                servedUndoRequest = undo
                if undo > 0 { view.undoManager?.undo() }
            }
            if redo != servedRedoRequest {
                servedRedoRequest = redo
                if redo > 0 { view.undoManager?.redo() }
            }
        }

        /// Pulls focus back when the host asks — after the slider or a sheet closes. Retries for the
        /// length of a dismissal, for the same reason the first focus does: UIKit refuses first
        /// responder while a presentation transition is in flight.
        func focusIfRequested(_ request: Int, in view: InlineTokenTextView) {
            guard request != servedFocusRequest else { return }
            servedFocusRequest = request
            guard request > 0 else { return }
            view.focusWhenAllowed()
        }

        /// The one attributed-string builder, shared with the read-only prose.
        private var attributes: InlineTokenAttributes {
            InlineTokenAttributes(
                style: style,
                palette: palette,
                dynamicTypeSize: dynamicTypeSize,
                displayScale: displayScale,
                colorScheme: colorScheme,
                selectedTokenID: typography.selectedTokenID
            )
        }

        func attributedString(for composition: EntryComposition) -> NSAttributedString {
            attributes.attributedString(for: composition)
        }

        func attachmentString(for token: EntryToken) -> NSAttributedString {
            attributes.attachmentString(for: token)
        }

        func baseAttributes() -> [NSAttributedString.Key: Any] {
            attributes.base()
        }

        // MARK: Storage → model

        func composition(from view: UITextView) -> EntryComposition {
            InlineTokenAttributes.composition(from: view.attributedText ?? NSAttributedString())
        }

        // MARK: UITextViewDelegate

        func textViewDidChange(_ textView: UITextView) {
            guard isRendering == false, let view = textView as? InlineTokenTextView else { return }
            view.placeholderLabel.isHidden = view.textStorage.length > 0
            // Typing inside or beside an attachment can leave the pill's own attributes on new
            // characters; normalise before deriving so a token can't smear.
            normaliseTokens(in: view)
            binding.wrappedValue = composition(from: view)
            // Noticed now, applied a turn later — see `scheduleScorePromotion`.
            if let promotion = promotableScore(in: view) { noticedPromotion = promotion }
            scheduleScorePromotion(in: view)
        }

        /// The promotion runs on the next turn of the runloop, **outside** UIKit's edit transaction.
        ///
        /// Doing it inside `textViewDidChange` mutated text the text view had not finished
        /// registering its undo operation for, so the operation ended up describing a range that no
        /// longer existed. Waiting a turn means the typing operation is fully registered before
        /// ``applyStorageEdit(in:caret:updatesBinding:)`` drops it, which is the difference between
        /// a coherent undo stack and a crash.
        ///
        /// **But a turn later is a different sentence.** The trigger is the character under the
        /// caret — a move-on straight after a digit — and when several keystrokes land in the same
        /// turn (a fast typist, a paste, dictation, a busy machine) the caret has moved past it by
        /// the time this runs, and the number quietly never became a pill. So the candidate is
        /// *noticed* in `textViewDidChange`, while it is still true, and applied here as long as the
        /// words at that range still read the number it was noticed for.
        private func scheduleScorePromotion(in view: InlineTokenTextView) {
            guard hasPendingPromotion == false else { return }
            hasPendingPromotion = true
            DispatchQueue.main.async { [weak self, weak view] in
                MainActor.assumeIsolated {
                    guard let self, let view else { return }
                    self.hasPendingPromotion = false
                    let noticed = self.noticedPromotion
                    self.noticedPromotion = nil
                    let stillThere = noticed.flatMap { self.stillReads($0, in: view) ? $0 : nil }
                    guard let promotion = self.promotableScore(in: view) ?? stillThere else { return }
                    self.apply(promotion, in: view)
                }
            }
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            // UIKit inherits typing attributes from the character before the caret. Beside a token
            // that character is an attachment — so without this, the next thing typed would come out
            // as a second copy of the pill. There is no other formatting in this editor, so the
            // typing attributes are always the base ones.
            textView.typingAttributes = baseAttributes()
            guard isRendering == false else { return }
            callbacks.onCaretChange(textView.selectedRange.location)
        }

        /// Two invariants, restored after every change the person makes.
        ///
        /// **A token never smears.** Typing beside an attachment, pasting, or autocorrect replacing a
        /// range that starts at one can leave the pill's attributes on ordinary characters; those
        /// lose them, so a token stays exactly one character wide.
        ///
        /// **A placeholder is never orphaned.** `replace(_:withText:)` records *plain* text, so
        /// redoing a promotion puts the placeholder character back without its attachment. Left
        /// alone it would be read as an ordinary character and POSTed as part of somebody's words —
        /// an invisible `U+FFFC` in their entry.
        ///
        /// So an orphan is re-attached to the token it came from when we still know it (redo of the
        /// promotion we just made: the pill comes back, which is what redo should mean), and deleted
        /// when we do not.
        private func normaliseTokens(in view: InlineTokenTextView) {
            let storage = view.textStorage
            let string = storage.string as NSString
            var stray: [NSRange] = []
            var orphans: [NSRange] = []
            var liveTokenIDs: Set<UUID> = []
            for index in 0..<storage.length {
                let isPlaceholder = string.character(at: index) == InlineTokenAttributes.objectReplacement
                let box = storage.attribute(.ateToken, at: index, effectiveRange: nil) as? TokenBox
                if let box, isPlaceholder {
                    liveTokenIDs.insert(box.token.id)
                } else if box != nil {
                    stray.append(NSRange(location: index, length: 1))
                } else if isPlaceholder {
                    orphans.append(NSRange(location: index, length: 1))
                }
            }
            guard stray.isEmpty == false || orphans.isEmpty == false else { return }

            // Undo or redo landed the text view back on words it has held before: put back the pills
            // that were in them. This is what makes *redo* of a dictation bring its score pills back
            // rather than deleting their placeholders.
            if orphans.isEmpty == false, stray.isEmpty, let known = rendered.tokens(for: storage.string) {
                isRendering = true
                let caret = view.selectedRange
                attach(known, in: view)
                view.selectedRange = caret
                view.typingAttributes = baseAttributes()
                isRendering = false
                return
            }

            // One orphan and a promotion whose token is nowhere in the storage: this is that
            // promotion coming back.
            let recovered = orphans.count == 1 && lastPromotedToken.map { liveTokenIDs.contains($0.id) } == false
                ? lastPromotedToken
                : nil

            let caret = view.selectedRange
            isRendering = true
            storage.beginEditing()
            for range in stray {
                storage.removeAttribute(.ateToken, range: range)
                storage.removeAttribute(.attachment, range: range)
                storage.addAttributes(baseAttributes(), range: range)
            }
            if let recovered, let range = orphans.first {
                storage.setAttributes(
                    attachmentString(for: recovered).attributes(at: 0, effectiveRange: nil),
                    range: range
                )
            } else {
                // Back to front: deleting shifts everything after it.
                for range in orphans.reversed() {
                    storage.replaceCharacters(in: range, with: "")
                }
            }
            storage.endEditing()
            let length = storage.length
            view.selectedRange = NSRange(
                location: min(caret.location, length),
                length: min(caret.length, max(0, length - min(caret.location, length)))
            )
            view.typingAttributes = baseAttributes()
            isRendering = false
        }

        /// A number the person has moved on from: where it sits, and what it is worth.
        struct Promotion {
            /// The digits, in display offsets.
            let range: NSRange
            /// What they read — checked again before the pill goes in, so a promotion noticed a turn
            /// ago can never land on characters that have changed since.
            let literal: String
            let token: EntryToken
        }

        /// "Typing a number after a dish becomes a score token." Read-only: the condition is the
        /// character under the caret — a move-on straight after a digit.
        private func promotableScore(in view: InlineTokenTextView) -> Promotion? {
            let caret = view.selectedRange
            guard caret.length == 0, caret.location > 0 else { return nil }
            let storage = view.textStorage
            let lastCharacter = storage.attributedSubstring(
                from: NSRange(location: caret.location - 1, length: 1)
            ).string
            let previous = caret.location >= 2
                ? storage.attributedSubstring(from: NSRange(location: caret.location - 2, length: 1)).string
                : ""
            guard ScoreLiteral.isMoveOn(
                lastCharacter,
                afterDigit: previous.count == 1 && previous.first?.isNumber == true
            ) else { return nil }

            let model = composition(from: view)
            // `pendingScoreLiteral` refuses a span a token already covers, so a pill put there by
            // the Score key is never "promoted" into a second, identical pill.
            guard let found = model.pendingScoreLiteral(atDisplayOffset: caret.location - 1) else { return nil }

            let start = model.displayOffset(forPlainOffset: found.span.location)
            let end = model.displayOffset(forPlainOffset: found.span.endLocation)
            let range = NSRange(location: start, length: end - start)
            guard let literal = text(at: range, in: view) else { return nil }
            return Promotion(range: range, literal: literal, token: EntryToken(kind: .score(found.rating)))
        }

        /// Whether the words still say there what they said when this was noticed.
        private func stillReads(_ promotion: Promotion, in view: InlineTokenTextView) -> Bool {
            text(at: promotion.range, in: view) == promotion.literal
        }

        private func text(at range: NSRange, in view: InlineTokenTextView) -> String? {
            let storage = view.textStorage
            guard range.location >= 0, range.length > 0, range.upperBound <= storage.length else { return nil }
            return storage.attributedSubstring(from: range).string
        }

        /// The digits out, one pill in.
        private func apply(_ promotion: Promotion, in view: InlineTokenTextView) {
            let caret = view.selectedRange.location
            let shift = 1 - promotion.range.length
            lastPromotedToken = promotion.token

            // One placeholder character in through the edit path, then its attachment as an
            // attribute. Undoing this restores the digits the person typed, which is what they
            // would expect and what UIKit's own operation now describes correctly.
            write(StorageEdit(
                text: String(EntryComposition.tokenPlaceholder),
                range: promotion.range,
                tokens: [EntryTokenSpan(
                    token: promotion.token,
                    span: TextSpan(location: promotion.range.location, length: 1)
                )],
                // The caret moves with the words only when it was after them. When the promotion is
                // landing behind a caret that has already typed on, where they are is where they stay.
                caret: caret >= promotion.range.upperBound ? caret + shift : caret,
                updatesBinding: true
            ), in: view)
            AteHaptics.tick()
            // `primaryLanguage == "dictation"` is how UIKit reports that the text arrived from the
            // keyboard's mic rather than its keys. It is the only signal there is, and being wrong
            // costs one mislabelled funnel event — never a word of anybody's entry.
            callbacks.onScorePromoted(view.textInputMode?.primaryLanguage == "dictation")
        }

        // MARK: Tapping — a token, or the writing area

        @objc
        func handleTap(_ recogniser: UITapGestureRecognizer) {
            guard let view = textView else { return }
            let point = recogniser.location(in: view)
            if let token = token(at: point, in: view) {
                callbacks.onTokenTap(token)
                return
            }
            // A tap anywhere else in the writing area puts the caret there and starts typing.
            if view.isFirstResponder == false {
                view.becomeFirstResponder()
            }
            guard let position = view.closestPosition(to: point) else { return }
            view.selectedRange = NSRange(
                location: view.offset(from: view.beginningOfDocument, to: position),
                length: 0
            )
        }

        private func token(at point: CGPoint, in view: UITextView) -> EntryToken? {
            guard view.textStorage.length > 0, let position = view.closestPosition(to: point) else { return nil }
            let offset = view.offset(from: view.beginningOfDocument, to: position)
            let model = binding.wrappedValue
            // `closestPosition` snaps to a character boundary, so a tap in the middle of a pill can
            // land on either side of it: check both.
            return model.token(atDisplayOffset: offset) ?? model.token(atDisplayOffset: offset - 1)
        }

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
}
