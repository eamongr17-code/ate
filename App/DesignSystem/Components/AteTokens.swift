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
            AteIcon.starFilled.view(size: style.size * 0.85, weight: .semibold)
            Text(ScoreFormat.halfStep(rating.value))
                .ateText(style)
                .monospacedDigit()
        }
        .padding(.leading, prose * 0.3)
        .padding(.trailing, prose * 0.41)
        .padding(.vertical, prose * 0.1)
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
        HStack(spacing: prose * 0.17) {
            AteIcon.place.view(size: style.size * 0.9, weight: .medium)
            Text(name)
                .ateText(style)
        }
        .padding(.leading, prose * 0.3)
        .padding(.trailing, prose * 0.47)
        .padding(.vertical, prose * 0.1)
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

    @Environment(\.atePalette) private var palette

    var body: some View {
        ZStack {
            AteIcon.star.view(size: side, weight: .light)
            AteIcon.starFilled.view(size: side, weight: .light)
                .foregroundStyle(AteColor.butter)
                .mask(alignment: .leading) {
                    Rectangle().frame(width: side * fill)
                }
            // The outline is drawn last so a half fill still reads as one whole star.
            AteIcon.star.view(size: side, weight: .light)
        }
        .foregroundStyle(palette.fg)
        .frame(width: side, height: side)
        .accessibilityHidden(true)
    }
}

/// An unscored line item: one empty star, no text (design rule 7 — a score is never inferred and
/// never written as a zero).
struct UnscoredMark: View {
    var side: CGFloat = 16

    var body: some View {
        AteStar(fill: 0, side: side)
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
            ForEach([0.0, 0.5, 1.0, 1.0, 0.0], id: \.self) { AteStar(fill: $0) }
        }
        UnscoredMark()
    }
    .padding(AteMetrics.gutter)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .ateGround()
}
#endif
