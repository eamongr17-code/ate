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
    /// Bumped to run the text view's own undo / redo. Only the debug undo drive does this: on a
    /// phone undo is a shake or a three-finger swipe, and neither can be driven by a UI test —
    /// while Cmd+Z needs a hardware keyboard, which would hide the software one this editor's other
    /// test asserts. Going through `UndoManager` runs the exact operations that used to crash.
    var undoRequest = 0
    var redoRequest = 0
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
    @Environment(\.colorScheme) private var colorScheme

    func makeUIView(context: Context) -> InlineTokenTextView {
        let view = InlineTokenTextView()
        view.delegate = context.coordinator
        view.coordinator = context.coordinator
        // The one handle a UI test needs to type into the composer. Nothing else in the app is a
        // text view, but naming it means a drive never depends on that staying true.
        view.accessibilityIdentifier = "composer.editor"
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
        context.coordinator.runUndoIfRequested(undo: undoRequest, redo: redoRequest, in: view)
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
        Typography(
            style: style, palette: palette, dynamicTypeSize: dynamicTypeSize,
            displayScale: displayScale, colorScheme: colorScheme
        )
    }

    private var callbacks: Callbacks {
        Callbacks(onTokenTap: onTokenTap, onCaretChange: onCaretChange, onScorePromoted: onScorePromoted)
    }

    struct Typography: Equatable {
        var style: AteTextStyle
        var palette: AtePalette
        var dynamicTypeSize: DynamicTypeSize
        var displayScale: CGFloat
        var colorScheme: ColorScheme
    }

    struct Callbacks {
        var onTokenTap: (EntryToken) -> Void
        var onCaretChange: (Int) -> Void
        var onScorePromoted: (Bool) -> Void
    }
}
