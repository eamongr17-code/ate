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
        case .tag: prose * dietHeightEm
        }
    }

    static func descent(for kind: EntryTokenKind, prose: CGFloat) -> CGFloat {
        switch kind {
        case .score: descent(height: height(for: kind, prose: prose), icon: starSide)
        case .place: descent(height: height(for: kind, prose: prose), icon: pinSide)
        // Centred on the score pill's box, so a dish's codes and its score sit level in the words.
        case .tag:
            descent(height: prose * scoreHeightEm, icon: starSide)
                - (prose * scoreHeightEm - height(for: kind, prose: prose)) / 2
        }
    }

    // **A diet chip is the score pill's sibling** (Eamon, 9 Oct): the same capsule and mono voice,
    // centred on the same line, but muted — the ground colour — so the score stays the headline.
    // **A step smaller than the score** (Eamon, build 103): at the same size a run of capitals reads
    // bigger than a star and three digits, so the chip and its letters are cut to `dietScale` of the
    // pill's. In the words it is proportioned off the prose like `.tok`; on its own (a dish row, a
    // slip's name) it is that chip at slip prose, 16.

    /// The optical step down from the score pill, for the chip and its letters alike.
    static let dietScale: CGFloat = 0.86
    static let dietHeightEm: CGFloat = scoreHeightEm * dietScale
    /// The chip on its own: the chip a 16pt slip's words would draw.
    static let dietHeight: CGFloat = (16 * dietHeightEm).rounded()
    /// The chip's inset at an end, a step in from the score pill's 7.
    static let dietPadding: CGFloat = 6
    /// Half the air between two codes inside one grouped chip — 7 between them, so `GF V` never
    /// reads as `GFV`.
    static let dietInnerPadding: CGFloat = 3.5
    /// `.prose .diet{margin:0 1px}` in the words…
    static let dietMarginInProse: CGFloat = 1
    /// …and `.dname .diet{margin-left:6px; vertical-align:3px}` after a dish's name.
    static let dietRiseOnName: CGFloat = 3
    static let dietGapOnName: CGFloat = 6
}

/// **A dietary tag** — the score pill's muted sibling: the code in capitals, DM Mono 500 like the
/// score's numeral, on the ground colour so it reads as the paper showing through rather than as an
/// accent. No stroke, no enamel. The same chip after a dish's name on a card and inline in the words.
struct DietTagChip: View {
    let tag: DietTag
    /// The ground showing through. Linen on paper and slips (the markup's own); on the linen ground
    /// itself — the dish page, a search row — the ground's recessed `field` tone, since a linen chip
    /// on linen is no chip at all (round 4). `nil` draws no fill: the caller wraps the chip in glass
    /// (``AteDietChips``).
    var fill: Color? = AteColor.tagFill
    /// Which sides run on into the dish's next and previous codes (``DietChipJoin``).
    var join: DietChipJoin = []
    /// The prose it sits in, when it is inline in the words: then it is proportioned off it like the
    /// score pill beside it. `nil` is the chip on its own.
    var prose: CGFloat?

    var body: some View {
        let height = prose.map { $0 * TokenPillMetrics.dietHeightEm } ?? TokenPillMetrics.dietHeight
        if prose != nil {
            // In the words it is an image, so it carries the glass's light rather than the glass
            // (``GlassSheen``) — the sheen only, so a grouped chip shows no seams.
            chip(height: height).ateGlassSheen(rim: false, in: join.shape(height: height))
        } else {
            chip(height: height)
        }
    }

    private func chip(height: CGFloat) -> some View {
        let style = prose.map(AteTextStyle.dietToken(inProse:)) ?? .dietTag
        return Text(tag.label)
            .ateText(style)
            .lineLimit(1)
            .fixedSize()
            .padding(.leading, join.padding(.leading))
            .padding(.trailing, join.padding(.trailing))
            .frame(height: height)
            .foregroundStyle(AteColor.tagInk)
            .background(fill ?? .clear, in: join.shape(height: height))
            .accessibilityElement()
            .accessibilityLabel(tag.spokenName)
    }
}

/// **A dish's codes are one chip** (Eamon, 7 Oct: "multiple dietaries should group together"). Two
/// or more codes on one dish draw as a single capsule — `GF V VG` — rather than a row of pills: each
/// code is a segment of it, square where it runs on into its neighbour.
struct DietChipJoin: OptionSet, Hashable {
    let rawValue: Int
    /// Runs on from the code before it.
    static let leading = DietChipJoin(rawValue: 1 << 0)
    /// Runs on into the code after it.
    static let trailing = DietChipJoin(rawValue: 1 << 1)

    /// Each code's place in a run of `count`.
    static func at(_ index: Int, of count: Int) -> DietChipJoin {
        var join: DietChipJoin = []
        if index > 0 { join.insert(.leading) }
        if index < count - 1 { join.insert(.trailing) }
        return join
    }

    /// The code's inset on one side: the chip's own 6 at an end, half the gap where it runs on.
    func padding(_ side: DietChipJoin) -> CGFloat {
        contains(side) ? TokenPillMetrics.dietInnerPadding : TokenPillMetrics.dietPadding
    }

    /// The capsule, cut square on the sides that run on.
    func shape(height: CGFloat) -> UnevenRoundedRectangle {
        let radius = height / 2
        let leading = contains(.leading) ? 0 : radius
        let trailing = contains(.trailing) ? 0 : radius
        return UnevenRoundedRectangle(
            topLeadingRadius: leading, bottomLeadingRadius: leading,
            bottomTrailingRadius: trailing, topTrailingRadius: trailing,
            style: .circular
        )
    }
}

extension AteTextStyle {
    /// A score token's numeral, sized against the prose it sits in — `.tok`'s `font-size:.78em`.
    /// **Not rounded**: `em` is a fraction in the markup, and rounding 12.48 to 12 took nearly a
    /// point off the width of every pill in a 16pt slip.
    static func scoreToken(inProse size: CGFloat) -> AteTextStyle {
        AteTextStyle(voice: .mono, size: size * 0.78, weight: 500, lineHeight: 1.0, textStyle: .footnote)
    }

    /// A diet chip's code in the words — the score numeral's own voice, a step smaller
    /// (``TokenPillMetrics/dietScale``) so a run of capitals doesn't outweigh the score, and opened
    /// a touch so the smaller codes stay legible.
    static func dietToken(inProse size: CGFloat) -> AteTextStyle {
        AteTextStyle(
            voice: .mono, size: size * 0.78 * TokenPillMetrics.dietScale, weight: 500,
            trackingEm: 0.04, lineHeight: 1.0, textStyle: .footnote
        )
    }

    /// A place token's name, sized against the prose it sits in — `.ptok`'s `font-size:.8em`.
    static func placeToken(inProse size: CGFloat) -> AteTextStyle {
        AteTextStyle(
            voice: .display, size: size * 0.8, weight: 600,
            trackingEm: -0.01, lineHeight: 1.0, textStyle: .footnote
        )
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
    /// What the pill prints, when it is not one person's half-step. See ``init(average:prose:)``.
    var printed: String?

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let style = AteTextStyle.scoreToken(inProse: prose)
        // `.tok`'s own line box, `line-height:1.55` of the numeral it carries — measured off the
        // numeral as it is actually set, so a pill on its own grows with Dynamic Type instead of
        // clipping its digits. At the design's size it is `.78em × 1.55` of the prose exactly.
        let height = AteFont.size(for: style, dynamicTypeSize: dynamicTypeSize)
            * TokenPillMetrics.scoreHeightEm / 0.78
        // A person's perfect 5.0 and their secret 6 dress differently (`ScoreStyle`); an aggregate
        // never does — an average of 5.0 is not anybody's perfect score.
        let dress = printed == nil ? ScoreStyle.of(rating) : .standard
        HStack(spacing: TokenPillMetrics.iconGap) {
            AteIcon.starFilled.view(size: TokenPillMetrics.starSide)
                .foregroundStyle(dress.star)
            Text(printed ?? ScoreFormat.halfStep(rating.value))
                .ateText(style)
                .monospacedDigit()
        }
        .padding(.leading, TokenPillMetrics.scoreLeading)
        .padding(.trailing, TokenPillMetrics.scoreTrailing)
        // 1.209em, which is 20.6 in 17pt prose. Not one em — that drew a squat capsule three and a
        // half points short of the artboard's.
        .frame(height: height)
        .foregroundStyle(dress.ink)
        .background(dress.fill, in: .capsule)
        .ateGlassSheen(onDarkFill: dress == .blownAway)
        .ateShimmerOnce(dress.shimmers)
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

extension ScoreToken {
    /// **An aggregate in the same pill** — a place's or a dish's community average, printed **as
    /// sent**, one decimal (`4.3`, `4.4`: `Search`, `SearchResults`, `Saved` all print them). Only a
    /// star glyph rounds to the half; a number in a pill is a price, and a price is not rounded
    /// (integration-design.md, "Printing an aggregate"). VoiceOver still hears the nearest half, like
    /// every other score.
    init(average: Double, prose: CGFloat = 17) {
        self.init(rating: Rating(rounding: average), prose: prose, printed: ScoreFormat.average(average))
    }
}

/// **The place token.** A field-coloured pill with a pin and the place's name, in the control voice.
/// Design rule 8 is enforced by its own existence: a place token is only ever in the text because
/// somebody named it or tapped it.
struct PlaceToken: View {
    let name: String
    var prose: CGFloat = 17

    @Environment(\.atePalette) private var palette
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let style = AteTextStyle.placeToken(inProse: prose)
        // `.ptok`'s own line box, `line-height:1.5` of the name as it is set (1.2em of the prose at
        // the design's size), so it grows with Dynamic Type rather than clipping.
        let height = AteFont.size(for: style, dynamicTypeSize: dynamicTypeSize)
            * TokenPillMetrics.placeHeightEm / 0.8
        HStack(spacing: TokenPillMetrics.iconGap) {
            AteIcon.place.view(size: TokenPillMetrics.pinSide)
            Text(name)
                .ateText(style)
        }
        .padding(.leading, TokenPillMetrics.placeLeading)
        .padding(.trailing, TokenPillMetrics.placeTrailing)
        .frame(height: height)
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
                    .fill(AteColor.scoreMark)
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
