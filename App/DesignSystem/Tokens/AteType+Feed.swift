import SwiftUI

// **The Feed's edition** (round 8, `Main.dc.html` / `Scrolled.dc.html`). Where the artboard sets no
// `line-height` the style takes the face's own `normal` (Bricolage and DM Mono both 1.2–1.3 of the
// size), which is what a single-line `Text` draws at by itself.

extension AteTextStyle {
    /// "Feed": `.b` 800 at 42, `letter-spacing:-1.8px`, `line-height:.95`.
    static let feedTitle = AteTextStyle(
        voice: .display, size: 42, weight: 800, trackingEm: -1.8 / 42, lineHeight: 0.95, textStyle: .largeTitle
    )
    /// A section's name — "The Top Ate", "New to the record", a craving: 800 at 28, `-0.9px`, 1.02.
    static let feedSection = AteTextStyle(
        voice: .display, size: 28, weight: 800, trackingEm: -0.9 / 28, lineHeight: 1.02, textStyle: .title
    )
    /// "See all", the Near me chip, "You're caught up": 600 at 15.
    static let feedControl = AteTextStyle(
        voice: .display, size: 15, weight: 600, trackingEm: 0, lineHeight: 1.2, textStyle: .subheadline
    )
    /// "Choose your cravings": 700 at 17.
    static let feedRow = AteTextStyle(
        voice: .display, size: 17, weight: 700, trackingEm: 0, lineHeight: 1.2, textStyle: .body
    )

    // The Top Ate — a receipt, so its numbers, places and scores are DM Mono.

    /// `01`…`08`: mono 15.
    static let topAteRank = AteTextStyle(
        voice: .mono, size: 15, weight: 400, lineHeight: 1.3, textStyle: .subheadline, maximumSize: 22
    )
    /// The first line's dish — 800 at 21, `-0.4px`, `line-height:1.12`…
    static let topAteLeadDish = AteTextStyle(
        voice: .display, size: 21, weight: 800, trackingEm: -0.4 / 21, lineHeight: 1.12, textStyle: .title3
    )
    /// …and every other line's, at 18.
    static let topAteDish = AteTextStyle(
        voice: .display, size: 18, weight: 800, trackingEm: -0.4 / 18, lineHeight: 1.12, textStyle: .headline
    )
    /// "TIPO 00, CBD": mono 12, capitals, `0.3px`.
    static let topAtePlace = AteTextStyle(
        voice: .mono, size: 12, weight: 400, trackingEm: 0.3 / 12, lineHeight: 1.3, textStyle: .caption,
        maximumSize: 18, uppercase: true
    )
    /// The first line's score, mono 19, and every other's at 16.
    static let topAteLeadScore = AteTextStyle(
        voice: .mono, size: 19, weight: 400, lineHeight: 1.3, textStyle: .title3, maximumSize: 26
    )
    static let topAteScore = AteTextStyle(
        voice: .mono, size: 16, weight: 400, lineHeight: 1.3, textStyle: .body, maximumSize: 22
    )

    // The cards and rows.

    /// A card's dish: 800 at 16, `-0.3px`, `line-height:1.12`.
    static let feedCardDish = AteTextStyle(
        voice: .display, size: 16, weight: 800, trackingEm: -0.3 / 16, lineHeight: 1.12, textStyle: .body
    )
    /// A card's and a row's place: `.b` at 14, muted. The page loads Bricolage from 500 up, so the
    /// browser draws the 400 it asks for at 500.
    static let feedPlace = AteTextStyle(
        voice: .display, size: 14, weight: 500, trackingEm: 0, lineHeight: 1.2, textStyle: .subheadline
    )
    /// The score on a card's photo — the score token: mono 13.
    static let feedCardScore = AteTextStyle(
        voice: .mono, size: 13, weight: 400, lineHeight: 1.3, textStyle: .footnote, maximumSize: 18
    )
    /// A New to the record row's dish: 800 at 17, `-0.3px`.
    static let feedNewDish = AteTextStyle(
        voice: .display, size: 17, weight: 800, trackingEm: -0.3 / 17, lineHeight: 1.2, textStyle: .body
    )
    /// Its badge — `★6`, `★5`, `New`: mono 12, `0.3px`.
    static let feedBadge = AteTextStyle(
        voice: .mono, size: 12, weight: 400, trackingEm: 0.3 / 12, lineHeight: 1.3, textStyle: .caption,
        maximumSize: 16
    )
}
