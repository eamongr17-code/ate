import AteKit
import SwiftUI

/// **The email code, six boxes** — the field-colour pills of `email-signin-share-links.html` A
/// (`.code span`), one digit in each, an ink ring on the next box to fill.
///
/// The typing goes into one TextField laid invisibly over the boxes, so iOS's code autofill from
/// Mail (`.oneTimeCode`), paste and delete all behave as one field would; the boxes only draw it.
struct AteCodeBoxes: View {
    @Binding var code: String
    var isFocused: FocusState<Bool>.Binding
    var isEnabled = true

    @Environment(\.atePalette) private var palette

    var body: some View {
        HStack(spacing: AteCodeBoxesMetrics.gap) {
            ForEach(0..<EmailSignInRules.codeLength, id: \.self) { index in
                box(index)
            }
        }
        .overlay {
            TextField("", text: Binding(get: { code }, set: { code = EmailSignInRules.code($0) }))
                .keyboardType(.numberPad)
                .textContentType(.oneTimeCode)
                .focused(isFocused)
                .disabled(isEnabled == false)
                // Invisible, but still the thing that is tapped and typed into.
                .foregroundStyle(.clear)
                .tint(.clear)
                .opacity(AteCodeBoxesMetrics.hiddenOpacity)
                .accessibilityLabel("Code")
                .accessibilityValue(code)
                .accessibilityIdentifier("email.code")
        }
        .opacity(isEnabled ? 1 : AteKitColor.disabledOpacity)
        .contentShape(.rect)
        .onTapGesture { isFocused.wrappedValue = true }
    }

    private func box(_ index: Int) -> some View {
        let digits = Array(code)
        let isNext = index == digits.count && isFocused.wrappedValue
        return Text(index < digits.count ? String(digits[index]) : "")
            .ateText(.kitCodeDigit)
            .foregroundStyle(palette.fg)
            .frame(maxWidth: .infinity)
            .frame(height: AteCodeBoxesMetrics.height)
            .background(palette.field, in: .capsule)
            .overlay {
                if isNext {
                    Capsule().strokeBorder(palette.fg, lineWidth: AteCodeBoxesMetrics.ring)
                }
            }
            .accessibilityHidden(true)
    }
}

enum AteCodeBoxesMetrics {
    static let gap: CGFloat = 8
    static let height: CGFloat = 62
    static let ring: CGFloat = 2
    /// Not zero: a view at opacity 0 stops taking taps and focus.
    static let hiddenOpacity: Double = 0.02
}
