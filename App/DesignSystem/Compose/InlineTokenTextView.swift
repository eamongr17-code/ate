import AteKit
import SwiftUI
import UIKit

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
        focusWhenAllowed()
    }

    func focusWhenAllowed(attemptsRemaining: Int = 12) {
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
