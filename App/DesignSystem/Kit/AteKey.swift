import AteKit
import SwiftUI

/// **A composer key** — the keys that float in the composer's glass capsule above the keyboard.
/// Score (butter, labelled) and Place (field, labelled, holding the chosen place and truncating at
/// 150) side by side, then Diet as a leaf alone in a 40 circle, which unfolds into the five codes.
/// The existing ``ComposerKey``, with each kind's dress decided once.
struct AteKey: View {
    enum Kind: Equatable {
        case score
        /// The place it holds, if one is attached.
        case place(String?)
        case diet
        /// One of the five codes the Diet key unfolds into.
        case code(DietTag)
        /// "Ate with" — fourth, after the leaf, the same 40 round key: the people on it, or the
        /// user-plus glyph when nobody is (``AteWithKeyFace``).
        case with([AteWithPerson])
    }

    let kind: Kind
    /// The Score key inverts while its slider is open: ink pill, butter lettering. A code is on (ink)
    /// when the dish already wears it, and pressing it takes it back off.
    var isActive = false
    let action: () -> Void

    var body: some View {
        switch kind {
        case .score:
            ComposerKey(
                title: "Score",
                icon: .starFilled,
                background: AteColor.scoreFill,
                foreground: AteColor.scoreInk,
                isActive: isActive,
                activeForeground: AteColor.butter,
                action: action
            )
            .fixedSize()
        case .place(let value):
            ComposerKey(
                title: "Place",
                icon: .place,
                iconSize: AteKeyMetrics.placeIcon,
                background: ComposerKeyColor.place,
                foreground: ComposerKeyColor.placeInk,
                value: value,
                identifier: "composer.key.place",
                action: action
            )
        case .diet:
            ComposerKey(
                title: "Diet",
                icon: .diet,
                iconSize: AteKeyMetrics.placeIcon,
                background: ComposerKeyColor.place,
                foreground: ComposerKeyColor.placeInk,
                iconOnly: true,
                action: action
            )
            .fixedSize()
        case .code(let tag):
            AteDietPill(tag: tag, isOn: isActive, identifier: "composer.diet.\(tag.rawValue)", action: action)
        case .with(let people):
            Button(action: action) { AteWithKeyFace(people: people).ateHitArea(.keyDisc) }
                .buttonStyle(.plain)
                .ateHitFootprint(.keyDisc)
                .fixedSize()
                .accessibilityLabel(people.isEmpty ? "With" : "With: " + people.map { "@\($0.handle)" }
                    .joined(separator: ", "))
                .accessibilityIdentifier("composer.key.with")
        }
    }
}

enum AteKeyMetrics {
    /// The Place pin and the Diet leaf are 16; the Score star 15.
    static let placeIcon: CGFloat = 16
}
