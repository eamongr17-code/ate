import AteKit
import SwiftUI
import UIKit

/// **The spike.** Free prose with a score pill and a place pill living *inside* the editable text —
/// the highest-risk interaction in the product, because everything else in the composer is a keyboard
/// and a button.
///
/// ## Why a `UITextView` and not `TextEditor`
///
/// iOS 26's `TextEditor(text: $attributedString)` edits an `AttributedString`, but its formatting
/// definition only reaches the attributes SwiftUI itself draws — weight, italic, colour, a rectangular
/// background. There is no rounded pill, no inline attachment, no hook to intercept a deletion so a
/// token dies whole, no way to hit-test a tap onto a token, and no caret control. A token there can
/// only ever be coloured text. `ComposerTextEditorVariant` in the gallery is that version, built and
/// running, so the limit can be seen rather than argued about.
///
/// ## How this one works
///
/// The text view owns the text — that is the whole trick. Autocorrect, predictive text, dictation,
/// undo, drag and drop, the caret and the selection are all untouched native behaviour, because
/// nothing intercepts typing. Each token is ONE `NSTextAttachment` (a `U+FFFC` character) carrying the
/// rendered pill and, alongside it, the `EntryToken` itself as a custom attribute.
///
/// One character per token is what buys the required behaviour for free:
/// - **backspace deletes a token whole** — it is a single character;
/// - **the caret can never land inside one**, and a selection can never cut one in half;
/// - the pill's metrics are exact, because the attachment's bounds are exact.
///
/// The model is then *derived* from the text storage after every change (`composition(from:)`), never
/// pushed into it mid-edit — so the person's words are whatever they typed, verbatim, and the tokens
/// are read back out of the attachments they are attached to.
struct InlineTokenEditor: UIViewRepresentable {
    @Binding var composition: EntryComposition
    /// Bumped by the host to force a rebuild of the text after a programmatic change (a token
    /// inserted from the Score key, a score changed on the slider).
    var revision: Int
    /// Where the caret should land after that rebuild, in display offsets.
    var caretAfterRender: Int?
    var style: AteTextStyle = .composerProse
    var placeholder: String = ""
    /// Raise the keyboard as soon as the editor is in a window. The composer opens straight into
    /// typing — an empty composer that needs a tap before it will take a word is a composer nobody
    /// writes in.
    var focusesOnAppear = true
    /// Bumped by the host to pull focus back after a sheet or the slider closes.
    var focusRequest = 0
    /// A token was tapped: reopen its slider or its sheet.
    var onTokenTap: (EntryToken) -> Void = { _ in }
    /// The caret moved. The host needs this to know where a new token should be inserted.
    var onCaretChange: (Int) -> Void = { _ in }
    /// The editor promoted a number the person had typed into a score token on its own. The flag is
    /// true when it arrived by dictation rather than the keyboard — the two are different products
    /// and the funnel has to be able to tell them apart.
    var onScorePromoted: (_ wasDictated: Bool) -> Void = { _ in }

    @Environment(\.atePalette) private var palette
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.displayScale) private var displayScale

    func makeUIView(context: Context) -> InlineTokenTextView {
        let view = InlineTokenTextView()
        view.delegate = context.coordinator
        view.coordinator = context.coordinator
        view.backgroundColor = .clear
        view.isScrollEnabled = true
        view.alwaysBounceVertical = true
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.keyboardDismissMode = .interactive
        view.autocorrectionType = .yes
        view.smartQuotesType = .yes
        view.smartDashesType = .yes

        // ONE recognizer, and it never blocks the text view's own: it is simultaneous, it does not
        // cancel touches, and when the tap missed a token it does the focusing itself. Relying on
        // UIKit's internal tap-to-focus alone is what left the empty composer dead to a tap — the
        // first thing Eamon found driving the spike.
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap(_:)))
        tap.cancelsTouchesInView = false
        tap.delegate = context.coordinator
        view.addGestureRecognizer(tap)
        view.focusesOnAppear = focusesOnAppear
        context.coordinator.textView = view
        context.coordinator.render(composition, revision: revision, caret: caretAfterRender, into: view)
        return view
    }

    func updateUIView(_ view: InlineTokenTextView, context: Context) {
        context.coordinator.update(binding: $composition, typography: typography, callbacks: callbacks)
        view.focusesOnAppear = focusesOnAppear
        context.coordinator.focusIfRequested(focusRequest, in: view)
        view.placeholderLabel.text = placeholder
        view.placeholderLabel.font = AteFont.uiFont(for: style, dynamicTypeSize: dynamicTypeSize)
        view.placeholderLabel.textColor = UIColor(palette.muted)
        view.placeholderLabel.isHidden = view.text.isEmpty == false

        // Re-render only when the host changed the model or the typography moved under us. During
        // typing the text view is ahead of the binding, and rewriting its storage would eat the caret.
        if context.coordinator.shouldRender(revision: revision, style: style, dynamicTypeSize: dynamicTypeSize) {
            context.coordinator.render(composition, revision: revision, caret: caretAfterRender, into: view)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(binding: $composition, typography: typography, callbacks: callbacks)
    }

    /// Everything the coordinator needs from the SwiftUI environment, as one value — so a change in
    /// the reader's text size or the surface's palette is one comparison, not five.
    private var typography: Typography {
        Typography(style: style, palette: palette, dynamicTypeSize: dynamicTypeSize, displayScale: displayScale)
    }

    private var callbacks: Callbacks {
        Callbacks(onTokenTap: onTokenTap, onCaretChange: onCaretChange, onScorePromoted: onScorePromoted)
    }

    struct Typography: Equatable {
        var style: AteTextStyle
        var palette: AtePalette
        var dynamicTypeSize: DynamicTypeSize
        var displayScale: CGFloat
    }

    struct Callbacks {
        var onTokenTap: (EntryToken) -> Void
        var onCaretChange: (Int) -> Void
        var onScorePromoted: (Bool) -> Void
    }

    // MARK: - Coordinator

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

        private var style: AteTextStyle { typography.style }
        private var palette: AtePalette { typography.palette }
        private var dynamicTypeSize: DynamicTypeSize { typography.dynamicTypeSize }
        private var displayScale: CGFloat { typography.displayScale }

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

        /// Writes a composition into the text view, putting the caret where the host asked for it — or
        /// leaving it where it was, if the host had no opinion.
        func render(_ composition: EntryComposition, revision: Int, caret: Int?, into view: InlineTokenTextView) {
            isRendering = true
            let previous = caret ?? view.selectedRange.location
            view.attributedText = attributedString(for: composition)
            view.typingAttributes = baseAttributes()
            let length = view.textStorage.length
            view.selectedRange = NSRange(location: min(max(0, previous), length), length: 0)
            view.placeholderLabel.isHidden = length > 0
            renderedRevision = revision
            renderedTypography = typography
            isRendering = false
            // `textViewDidChangeSelection` is suppressed while rendering, so the host would never
            // hear where the caret landed — and the NEXT token would be inserted at the stale offset
            // (the caret readout stuck at 0 after inserting one). Report it explicitly.
            callbacks.onCaretChange(view.selectedRange.location)
        }

        /// Pulls focus back when the host asks — after the slider or a sheet closes.
        func focusIfRequested(_ request: Int, in view: InlineTokenTextView) {
            guard request != servedFocusRequest else { return }
            servedFocusRequest = request
            guard request > 0 else { return }
            view.becomeFirstResponder()
        }

        /// The one attributed-string builder, shared with the read-only prose.
        private var attributes: InlineTokenAttributes {
            InlineTokenAttributes(
                style: style,
                palette: palette,
                dynamicTypeSize: dynamicTypeSize,
                displayScale: displayScale
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
            scrubStrayTokenAttributes(in: view)
            binding.wrappedValue = composition(from: view)
            promoteScoreLiteralIfMovedOn(in: view)
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

        /// Belt and braces for paste and for autocorrect replacing a range that starts at a token: any
        /// character that is not the attachment itself loses the token's attributes, so a token can
        /// never smear across the words beside it.
        private func scrubStrayTokenAttributes(in view: InlineTokenTextView) {
            let storage = view.textStorage
            let string = storage.string as NSString
            var stray: [NSRange] = []
            storage.enumerateAttribute(.ateToken, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
                guard value != nil else { return }
                for index in range.location..<(range.location + range.length)
                where string.character(at: index) != InlineTokenAttributes.objectReplacement {
                    stray.append(NSRange(location: index, length: 1))
                }
            }
            guard stray.isEmpty == false else { return }
            let caret = view.selectedRange
            isRendering = true
            storage.beginEditing()
            for range in stray {
                storage.removeAttribute(.ateToken, range: range)
                storage.removeAttribute(.attachment, range: range)
                storage.addAttributes(baseAttributes(), range: range)
            }
            storage.endEditing()
            view.selectedRange = caret
            view.typingAttributes = baseAttributes()
            isRendering = false
        }

        /// "Typing a number after a dish becomes a score token." Runs after every change: when the last
        /// thing typed was a move-on character, the number just before it is promoted in place.
        private func promoteScoreLiteralIfMovedOn(in view: InlineTokenTextView) {
            let caret = view.selectedRange
            guard caret.length == 0, caret.location > 0 else { return }
            let storage = view.textStorage
            let lastCharacter = storage.attributedSubstring(
                from: NSRange(location: caret.location - 1, length: 1)
            ).string
            guard ScoreLiteral.isMoveOn(lastCharacter) else { return }

            let model = binding.wrappedValue
            let plainCaret = model.plainOffset(forDisplayOffset: caret.location - 1)
            guard let found = ScoreLiteral.candidate(in: model.plain, caretUTF16: plainCaret) else { return }

            let start = model.displayOffset(forPlainOffset: found.span.location)
            let end = model.displayOffset(forPlainOffset: found.span.endLocation)
            let token = EntryToken(kind: .score(found.rating))

            isRendering = true
            storage.beginEditing()
            storage.replaceCharacters(
                in: NSRange(location: start, length: end - start),
                with: attachmentString(for: token)
            )
            storage.endEditing()
            let shift = 1 - (end - start)
            view.selectedRange = NSRange(location: caret.location + shift, length: 0)
            view.typingAttributes = baseAttributes()
            isRendering = false
            binding.wrappedValue = composition(from: view)
            callbacks.onCaretChange(view.selectedRange.location)
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

// MARK: - The view

/// A `UITextView` with a placeholder and a plain-text pasteboard.
final class InlineTokenTextView: UITextView {
    let placeholderLabel = UILabel()
    weak var coordinator: InlineTokenEditor.Coordinator?
    /// Raise the keyboard the moment the editor is in a window.
    var focusesOnAppear = false
    private var hasFocusedOnAppear = false

    /// `becomeFirstResponder()` in `makeUIView` is too early — the view has no window yet and the
    /// call is dropped. This is the hook that is never too early.
    ///
    /// It can still be too *late* to succeed on the first try: UIKit refuses first responder while a
    /// presentation transition is in flight, and the composer arrives in a `fullScreenCover`. So the
    /// attempt retries for the length of a presentation and then gives up — a composer that opens
    /// without a keyboard is a composer nobody writes in, and it was flaky, which is worse.
    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil, focusesOnAppear, hasFocusedOnAppear == false else { return }
        hasFocusedOnAppear = true
        focusWhenAllowed(attemptsRemaining: 12)
    }

    private func focusWhenAllowed(attemptsRemaining: Int) {
        guard isFirstResponder == false else { return }
        if becomeFirstResponder() { return }
        guard attemptsRemaining > 0 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.focusWhenAllowed(attemptsRemaining: attemptsRemaining - 1)
        }
    }

    override init(frame: CGRect, textContainer: NSTextContainer?) {
        super.init(frame: frame, textContainer: textContainer)
        placeholderLabel.numberOfLines = 0
        placeholderLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(placeholderLabel)
        NSLayoutConstraint.activate([
            placeholderLabel.topAnchor.constraint(equalTo: topAnchor),
            placeholderLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            placeholderLabel.trailingAnchor.constraint(equalTo: trailingAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    /// Copying a token must yield its WORDS. Without this, a pill on the pasteboard is a `U+FFFC` and
    /// pasting a review into Messages loses the score entirely.
    override func copy(_ sender: Any?) {
        guard let plain = selectedPlainText() else { return super.copy(sender) }
        UIPasteboard.general.string = plain
    }

    override func cut(_ sender: Any?) {
        guard let plain = selectedPlainText(), let range = selectedTextRange else { return super.cut(sender) }
        UIPasteboard.general.string = plain
        replace(range, withText: "")
    }

    private func selectedPlainText() -> String? {
        guard let coordinator, selectedRange.length > 0 else { return nil }
        let model = coordinator.composition(from: self)
        return model.plainText(inDisplaySpan: TextSpan(selectedRange))
    }
}
