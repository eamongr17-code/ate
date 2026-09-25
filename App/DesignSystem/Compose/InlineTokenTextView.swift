import AteKit
import SwiftUI
import UIKit

/// `Composer.dc.html`'s `.caret`, in points at the 19pt prose it is drawn in.
enum CaretMetrics {
    static let designProse: CGFloat = 19
    /// `width:2px`.
    static let width: CGFloat = 2
    /// `height:22px`.
    static let height: CGFloat = 22
    /// `vertical-align:-4px`: how far the caret's foot hangs below the baseline.
    static let drop: CGFloat = 4
    /// `margin-left:1px`.
    static let gap: CGFloat = 1
}

/// A `UITextView` with a placeholder, a plain-text pasteboard, and the design's caret.
final class InlineTokenTextView: UITextView {
    let placeholderLabel = UILabel()
    weak var coordinator: InlineTokenEditor.Coordinator?
    /// Raise the keyboard the moment the editor is in a window.
    var focusesOnAppear = false
    /// Something is laid over the editor that takes the place of the keyboard — `ComposerVoice`. No
    /// focus attempt may raise the keyboard over it, including the retries of the first one.
    var isFocusSuspended = false
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
        focusWhenAllowed()
    }

    func focusWhenAllowed(attemptsRemaining: Int = 12) {
        guard isFirstResponder == false, isFocusSuspended == false else { return }
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

    // MARK: - The caret

    /// **The caret `Composer.dc.html` draws**: `width:2px; height:22px; margin-left:1px;
    /// vertical-align:-4px` in 19pt prose — two points wide, a point clear of the last glyph, and
    /// hung off the **baseline**: four points below it, eighteen above.
    ///
    /// UIKit's own caret is not hung off anything the design can name. It is the height of the font's
    /// box plus a share of the clamped line box, so it ran from 20 above the baseline to 6.7 below —
    /// 26.7 tall, dropping under the words and the pills beside it on every line — and in the empty
    /// composer it sat half a line below the placeholder it was meant to start. Measured on the
    /// iPhone 17e simulator; see the lane's before/after captures.
    ///
    /// Everything scales with the prose size, so a reader at a larger text size gets the same caret in
    /// proportion.
    override func caretRect(for position: UITextPosition) -> CGRect {
        let system = super.caretRect(for: position)
        guard system.isNull == false, system.isInfinite == false,
              let font = typingAttributes[.font] as? UIFont else { return system }
        let em = font.pointSize / CaretMetrics.designProse
        guard let baseline = baseline(near: system, font: font) else { return system }
        return CGRect(
            x: system.minX + CaretMetrics.gap * em,
            y: baseline - (CaretMetrics.height - CaretMetrics.drop) * em,
            width: CaretMetrics.width,
            height: CaretMetrics.height * em
        )
    }

    /// The baseline of the line the system caret is on, read off TextKit 2's own line fragments — the
    /// same geometry the glyphs were drawn with, so the caret and the words cannot disagree.
    private func baseline(near caret: CGRect, font: UIFont) -> CGFloat? {
        guard textStorage.length > 0 else { return emptyBaseline(font: font) }
        guard let layout = textLayoutManager else { return nil }
        let origin = CGPoint(x: textContainerInset.left, y: textContainerInset.top)
        var best: (distance: CGFloat, baseline: CGFloat)?
        layout.enumerateTextLayoutFragments(
            from: layout.documentRange.location,
            options: [.ensuresLayout]
        ) { fragment in
            let frame = fragment.layoutFragmentFrame
            // Past the caret's line and then some: nothing further down can be closer.
            if frame.minY + origin.y > caret.maxY + font.pointSize * 2 { return false }
            for line in fragment.textLineFragments {
                let top = frame.minY + origin.y + line.typographicBounds.minY
                let bottom = frame.minY + origin.y + line.typographicBounds.maxY
                let distance = caret.midY < top ? top - caret.midY
                    : caret.midY > bottom ? caret.midY - bottom : 0
                let baseline = top + line.glyphOrigin.y
                if best.map({ distance < $0.distance }) ?? true { best = (distance, baseline) }
            }
            return true
        }
        return best?.baseline
    }

    /// No words yet, so no line to read: where the first line's baseline *will* be — the floor of the
    /// clamped line box, less the font's descent, which is exactly how TextKit sets the first line.
    private func emptyBaseline(font: UIFont) -> CGFloat {
        let paragraph = typingAttributes[.paragraphStyle] as? NSParagraphStyle
        let line = max(paragraph?.minimumLineHeight ?? 0, font.lineHeight)
        return textContainerInset.top + line + font.descender
    }

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

    /// An `NSRange` as the `UITextInput` world addresses it — the coordinate change that
    /// `replace(_:withText:)` needs. `nil` when the document cannot address that range yet, which
    /// happens once, on the first render before the view is in a window.
    func textRange(for range: NSRange) -> UITextRange? {
        guard let start = position(from: beginningOfDocument, offset: range.location),
              let end = position(from: start, offset: range.length) else { return nil }
        return textRange(from: start, to: end)
    }

    private func selectedPlainText() -> String? {
        guard let coordinator, selectedRange.length > 0 else { return nil }
        let model = coordinator.composition(from: self)
        return model.plainText(inDisplaySpan: TextSpan(selectedRange))
    }
}
