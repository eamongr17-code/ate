import AteKit
import SwiftUI

/// **A composer key** — the keys that float in the composer's glass capsule above the keyboard.
/// Score (butter) and Diet (field), both labelled: the two keys that put a pill into the words. Diet
/// unfolds into the diet codes. Place and people are the composer's byline (``AteComposerByline``).
/// The existing ``ComposerKey``, with each kind's dress decided once.
struct AteKey: View {
    enum Kind: Equatable {
        case score
        case diet
        /// One of the codes the Diet key unfolds into.
        case code(DietTag)
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
        case .diet:
            ComposerKey(
                title: "Diet",
                icon: .diet,
                iconSize: AteKeyMetrics.dietIcon,
                background: ComposerKeyColor.place,
                foreground: ComposerKeyColor.placeInk,
                identifier: "composer.key.diet",
                action: action
            )
            .fixedSize()
        case .code(let tag):
            AteDietPill(tag: tag, isOn: isActive, identifier: "composer.diet.\(tag.rawValue)", action: action)
        }
    }
}

enum AteKeyMetrics {
    /// The Diet leaf is 16; the Score star 15.
    static let dietIcon: CGFloat = 16
}
