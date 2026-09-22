import AteKit
import SwiftUI

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
        HStack(spacing: prose * 0.17) {
            AteIcon.starFilled.view(size: Self.starSide)
            Text(ScoreFormat.halfStep(rating.value))
                .ateText(style)
                .monospacedDigit()
        }
        .padding(.leading, prose * 0.3)
        .padding(.trailing, prose * 0.41)
        // Exactly one em tall. A pill any taller than the prose's ascent-plus-descent silently adds
        // leading to every line it lands on, and a paragraph with three scores in it ends up with a
        // different rhythm from one with none.
        .frame(height: prose.rounded())
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

    /// `.tok`'s star is 11 at every prose size the artboards set it in (16 and 19 both).
    private static let starSide: CGFloat = 11
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
        HStack(spacing: prose * 0.17) {
            AteIcon.place.view(size: Self.pinSide)
            Text(name)
                .ateText(style)
        }
        .padding(.leading, prose * 0.3)
        .padding(.trailing, prose * 0.47)
        .frame(height: prose.rounded())
        .foregroundStyle(palette.fg)
        .background(palette.field, in: .capsule)
        .accessibilityElement()
        .accessibilityLabel("Place")
        .accessibilityValue(name)
    }

    /// `.ptok`'s pin is 12 at every prose size the artboards set it in.
    private static let pinSide: CGFloat = 12
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

/// An unscored line item: one empty star, no text (design rule 7 — a score is never inferred and
/// never written as a zero). The receipt's own line weight, 1.8.
struct UnscoredMark: View {
    var side: CGFloat = 16

    var body: some View {
        AteIcon.star.view(size: side)
            .accessibilityHidden(false)
            .accessibilityLabel("Not scored")
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
        UnscoredMark()
    }
    .padding(AteMetrics.gutter)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .ateGround()
}
#endif
