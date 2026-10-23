import SwiftUI

/// **A choice that toggles in place** — the cravings sheet's `.pk`: 42 high, DM Sans 600 at 16,
/// the field colour when off and ink with light lettering when on. Many can be on; the sheet's ink
/// pill commits them. A 44 target.
struct AteTogglePill: View {
    enum Size: Equatable {
        /// The cravings sheet's `.pk`: 42 high, 600 at 16.
        case sheet
        /// A first-run step's choices (`diet.html` `.pk`): 48 high, `padding:0 20px`, 600 at 17.
        case large
    }

    let title: String
    var isOn = false
    /// Lit by another choice that covers it (Vegan covers Vegetarian): on, faded, and not a button.
    var isCovered = false
    var size: Size = .sheet
    var identifier: String?
    let action: () -> Void

    @Environment(\.atePalette) private var palette

    var body: some View {
        let isLit = isOn || isCovered
        // A covered pill answers nothing — not `.disabled`, which would dim it a second time.
        Button { if isCovered == false { action() } } label: {
            Text(title)
                .ateText(size == .large ? .kitTogglePillLarge : .kitInkPill)
                .lineLimit(1)
                .padding(.horizontal, padding)
                .frame(height: height)
                .foregroundStyle(isLit ? palette.inverted : palette.fg)
                .background(isLit ? palette.solid : palette.field, in: .capsule)
                .opacity(isCovered ? AteKitColor.coveredChipOpacity : 1)
                .padding(.vertical, hitOutset)
                .contentShape(.rect)
                .padding(.vertical, -hitOutset)
        }
        .buttonStyle(.plain)
        .fixedSize()
        .accessibilityAddTraits(isLit ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier(identifier ?? "toggle.\(title)")
    }

    private var height: CGFloat {
        size == .large ? AteTogglePillMetrics.largeHeight : AteTogglePillMetrics.height
    }

    private var padding: CGFloat {
        size == .large ? AteTogglePillMetrics.largePadding : AteTogglePillMetrics.padding
    }

    private var hitOutset: CGFloat { max(0, (AteMetrics.hit - height) / 2) }
}

/// Toggle pills in wrapping rows (`.pks{flex-wrap:wrap; gap:8px}`; the first-run step's `gap:10px`,
/// centred).
struct AteTogglePillFlow<Content: View>: View {
    var spacing: CGFloat = AteMetrics.snug
    var isCentred = false
    @ViewBuilder var content: Content

    var body: some View {
        AteFlow(spacing: spacing, centresLines: isCentred) { content }
    }
}

enum AteTogglePillMetrics {
    /// `.pk{height:42px; padding:0 16px}`.
    static let height: CGFloat = 42
    static let padding: CGFloat = 16
    static let hitOutset: CGFloat = (AteMetrics.hit - height) / 2
    /// `diet.html` `.pk{height:48px; padding:0 20px}`, and `.pks{gap:10px}`.
    static let largeHeight: CGFloat = 48
    static let largePadding: CGFloat = 20
    static let largeGap: CGFloat = 10
}
