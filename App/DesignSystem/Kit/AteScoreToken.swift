import AteKit
import SwiftUI

/// **A score, as the kit carries it.** One person's half-step (which can be a perfect 5.0 or the
/// secret 6, and dresses as one), or a community aggregate (which never does — an average of 5.0 is
/// not somebody's perfect score). Scores are never inferred: no score is `nil`, never a zero.
enum AteScore: Equatable, Sendable {
    case personal(Rating)
    case average(Double)
}

/// **The score token** — a filled star and one decimal on a butter pill, in DM Mono 500. Brick with
/// white lettering for a secret 6; a one-shot sweep on a 5.0 and a 6 (``ScoreStyle``). An unrated
/// dish renders **nothing**: the slot stays empty — no star, no zero, no dash, never dimmed.
///
/// Three sizes, one anatomy:
/// - ``Size/inline(prose:)`` — inside the words, sized against them (`.tok`, `.78em`). This is the
///   existing ``ScoreToken``, untouched.
/// - ``Size/row`` — a dish row, a ranked row, a shelf card's corner (`.tok` at 13, `padding:2px 9px
///   2px 7px`).
/// - ``Size/hero`` — the hero card's corner (`.tok` at 17, same padding).
struct AteScoreToken: View {
    enum Size: Equatable {
        case inline(prose: CGFloat)
        case row
        case hero
    }

    let score: AteScore?
    var size: Size = .row

    init(_ score: AteScore?, size: Size = .row) {
        self.score = score
        self.size = size
    }

    /// One person's score; `nil` is unrated.
    init(rating: Rating?, size: Size = .row) {
        self.init(rating.map(AteScore.personal), size: size)
    }

    /// A community aggregate, printed as sent to one decimal; `nil` is unrated.
    init(average: Double?, size: Size = .row) {
        self.init(average.map(AteScore.average), size: size)
    }

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        if let score {
            switch size {
            case .inline(let prose):
                switch score {
                case .personal(let rating): ScoreToken(rating: rating, prose: prose)
                case .average(let value): ScoreToken(average: value, prose: prose)
                }
            case .row:
                pill(score, metrics: .row)
            case .hero:
                pill(score, metrics: .hero)
            }
        }
    }

    private func pill(_ score: AteScore, metrics: AteScoreTokenMetrics) -> some View {
        let style = AteTextStyle.kitScoreToken(metrics.numeral)
        let drawn = AteFont.size(for: style, dynamicTypeSize: dynamicTypeSize)
        let dress: ScoreStyle
        let printed: String
        let rating: Rating
        switch score {
        case .personal(let value):
            dress = .of(value)
            printed = ScoreFormat.halfStep(value.value)
            rating = value
        case .average(let value):
            dress = .standard
            printed = ScoreFormat.average(value)
            rating = Rating(rounding: value)
        }
        return HStack(spacing: AteScoreTokenMetrics.gap) {
            AteIcon.starFilled.view(size: metrics.star)
                .foregroundStyle(dress.star)
            Text(printed)
                .ateText(style)
                .monospacedDigit()
        }
        .padding(.leading, metrics.leading)
        .padding(.trailing, metrics.trailing)
        // `line-height:1.55` of the numeral as drawn, plus the 2pt top and bottom padding — so the
        // pill grows with Dynamic Type instead of clipping its digits.
        .frame(height: drawn * AteScoreTokenMetrics.lineHeight + 2 * metrics.vertical)
        .foregroundStyle(dress.ink)
        // Live, so the real thing: Liquid Glass tinted butter (brick for a 6) (Eamon, 9 Oct).
        .ateGlassPill(dress.fill, in: .capsule)
        .ateShimmerOnce(dress.shimmers)
        .fixedSize()
        .accessibilityElement()
        .accessibilityLabel("Score")
        .accessibilityValue(RatingTrack.accessibilityValue(rating))
    }
}

/// The two fixed sizes' numbers, off `feed.html`'s `tok()` and `.card .p .tok`.
struct AteScoreTokenMetrics {
    let numeral: CGFloat
    /// `I('star', round(fs * .85))` — 11 at 13, 14 at 17.
    let star: CGFloat
    let leading: CGFloat
    let trailing: CGFloat
    let vertical: CGFloat

    static let row = AteScoreTokenMetrics(numeral: 13, star: 11, leading: 7, trailing: 9, vertical: 2)
    static let hero = AteScoreTokenMetrics(numeral: 17, star: 14, leading: 7, trailing: 9, vertical: 2)

    /// `gap:3px` between the star and the numeral; `line-height:1.55`.
    static let gap: CGFloat = 3
    static let lineHeight: CGFloat = 1.55
}
