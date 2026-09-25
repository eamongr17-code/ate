import AteKit
import SwiftUI

/// **How an inline pill is proportioned and where it sits**, straight off `.tok` and `.ptok`.
///
/// Both are `display:inline-flex`, so a pill's **height is its own line box** — `font-size ×
/// line-height` of the em it is set in — not one em of the prose around it. And both carry
/// `vertical-align:1px` on a flex box whose baseline is its first item's: the **icon's bottom edge**
/// lands 1pt above the prose baseline, and the pill's own padding carries on past it. That last part
/// is the whole reason a pill reads as a word in the sentence rather than a chip dropped into it.
enum TokenPillMetrics {
    /// `.tok`: `font-size:.78em; line-height:1.55`.
    static let scoreHeightEm: CGFloat = 0.78 * 1.55
    /// `.ptok`: `font-size:.8em; line-height:1.5`.
    static let placeHeightEm: CGFloat = 0.8 * 1.5
    /// The icons, 11 and 12 at every prose size the artboards set them in (16, 17 and 19 alike).
    static let starSide: CGFloat = 11
    static let pinSide: CGFloat = 12
    /// `vertical-align:1px`.
    static let riseAboveBaseline: CGFloat = 1

    // The paddings and the gap are **absolute** in the markup — `padding:0 7px 0 5px`, `gap:3px` —
    // not fractions of the em the pill sits in. Written as em fractions they happened to land at 17pt
    // prose and came out nearly two points narrow in a 16pt slip.

    /// `.tok`: `padding:0 7px 0 5px`.
    static let scoreLeading: CGFloat = 5
    static let scoreTrailing: CGFloat = 7
    /// `.ptok`: `padding:0 8px 0 5px`.
    static let placeLeading: CGFloat = 5
    static let placeTrailing: CGFloat = 8
    /// `gap:3px`, both.
    static let iconGap: CGFloat = 3

    /// How far the pill hangs **below** the prose baseline: half the air around its icon, less the
    /// point the artboard lifts it by.
    static func descent(height: CGFloat, icon: CGFloat) -> CGFloat {
        (height - icon) / 2 - riseAboveBaseline
    }

    static func height(for kind: EntryTokenKind, prose: CGFloat) -> CGFloat {
        switch kind {
        case .score: prose * scoreHeightEm
        case .place: prose * placeHeightEm
        }
    }

    static func descent(for kind: EntryTokenKind, prose: CGFloat) -> CGFloat {
        switch kind {
        case .score: descent(height: height(for: kind, prose: prose), icon: starSide)
        case .place: descent(height: height(for: kind, prose: prose), icon: pinSide)
        }
    }
}

/// **The score token.** A butter pill carrying a filled star and one decimal, in mono — a score
/// printed like a price (design rule 7). It appears inline in prose, inside a receipt's line items,
/// and in the composer's editable text, and it is the same object in all three.
struct ScoreToken: View {
    let rating: Rating
    /// The prose size it sits in; the pill is proportioned from it (0.78em in the prototype).
    var prose: CGFloat = 17
    /// Ringed in ink while its slider is open.
    var isSelected = false

    var body: some View {
        let style = AteTextStyle.scoreToken(inProse: prose)
        HStack(spacing: TokenPillMetrics.iconGap) {
            AteIcon.starFilled.view(size: TokenPillMetrics.starSide)
            Text(ScoreFormat.halfStep(rating.value))
                .ateText(style)
                .monospacedDigit()
        }
        .padding(.leading, TokenPillMetrics.scoreLeading)
        .padding(.trailing, TokenPillMetrics.scoreTrailing)
        // `.tok`'s own line box: `.78em × 1.55` = 1.209em, which is 20.6 in 17pt prose. Not one em —
        // that drew a squat capsule three and a half points short of the artboard's.
        .frame(height: prose * TokenPillMetrics.scoreHeightEm)
        .foregroundStyle(AteColor.ink)
        .background(AteColor.butter, in: .capsule)
        .overlay {
            if isSelected {
                Capsule().strokeBorder(AteColor.ink, lineWidth: 2)
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Score")
        .accessibilityValue(RatingTrack.accessibilityValue(rating))
    }
}

/// **The place token.** A field-coloured pill with a pin and the place's name, in the control voice.
/// Design rule 8 is enforced by its own existence: a place token is only ever in the text because
/// somebody named it or tapped it.
struct PlaceToken: View {
    let name: String
    var prose: CGFloat = 17

    @Environment(\.atePalette) private var palette

    var body: some View {
        let style = AteTextStyle.placeToken(inProse: prose)
        HStack(spacing: TokenPillMetrics.iconGap) {
            AteIcon.place.view(size: TokenPillMetrics.pinSide)
            Text(name)
                .ateText(style)
        }
        .padding(.leading, TokenPillMetrics.placeLeading)
        .padding(.trailing, TokenPillMetrics.placeTrailing)
        // `.ptok`'s own line box: `.8em × 1.5` = 1.2em.
        .frame(height: prose * TokenPillMetrics.placeHeightEm)
        .foregroundStyle(palette.fg)
        .background(palette.field, in: .capsule)
        .accessibilityElement()
        .accessibilityLabel("Place")
        .accessibilityValue(name)
    }
}

/// A star, solid-outlined and fillable by a fraction. Design rule 7: **stars are never low-opacity** —
/// an unscored star is a full-strength outline, because "nothing here yet" is a state, not a disabled
/// control.
struct AteStar: View {
    /// 0 = outline, 0.5 = half-filled, 1 = filled.
    var fill: Double
    var side: CGFloat = AteMetrics.star
    /// `ComposerStars` strokes the slider's stars at 1.3, not the chrome's 1.8 — they are 44 across
    /// and the heavier line closes the points up.
    var lineWidth: CGFloat = 1.3

    @Environment(\.atePalette) private var palette

    var body: some View {
        ZStack(alignment: .leading) {
            outline
            // The filled star is a second, complete drawing clipped to the fraction — measured
            // against the STAR, not against whatever column it was handed, or a half reads as a
            // quarter in the slider's equal columns.
            ZStack {
                AteIconShape(paths: AteIcon.starFilled.fills)
                    .fill(AteColor.butter)
                outline
            }
            .frame(width: side, height: side)
            .mask(alignment: .leading) {
                Rectangle().frame(width: side * fill, height: side)
            }
        }
        .frame(width: side, height: side)
        .foregroundStyle(palette.fg)
        .accessibilityHidden(true)
    }

    private var outline: some View {
        AteIconShape(paths: AteIcon.star.strokes)
            .stroke(style: StrokeStyle(
                lineWidth: lineWidth * side / AteVector.viewBox, lineCap: .round, lineJoin: .round
            ))
            .frame(width: side, height: side)
    }
}

#if DEBUG
#Preview("Tokens") {
    VStack(alignment: .leading, spacing: AteMetrics.loose) {
        HStack {
            ScoreToken(rating: Rating(rounding: 4.5))
            ScoreToken(rating: Rating(rounding: 3), isSelected: true)
            ScoreToken(rating: Rating(rounding: 5), prose: 19)
        }
        HStack {
            PlaceToken(name: "Tipo 00")
            PlaceToken(name: "Butchers Diner", prose: 19)
        }
        HStack(spacing: 0) {
            ForEach(Array([0.0, 0.5, 1.0, 1.0, 0.0].enumerated()), id: \.offset) { _, fill in
                AteStar(fill: fill)
            }
        }
    }
    .padding(AteMetrics.gutter)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .ateGround()
}
#endif
