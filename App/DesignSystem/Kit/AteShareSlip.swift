import AteKit
import SwiftUI

/// **The share sticker** (10 Oct, Eamon: "simplify it a bit… it needs to look good in a small
/// space"): the receipt stripped to what a glance needs, drawn to be stuck on a photo at a third of
/// a story's width. Dish left, score right, no dot leader; the top score marked in butter so one
/// number reads first; one dashed rule; one line of fine print (the place and its suburb, never the
/// street); the signature and the wordmark. No order number, date, count or average — those stay
/// on the receipt in the app. Scores never inferred: an unscored dish keeps an empty column.
///
/// One drawing at one width (``AteShareSlipMetrics/width``) for the screen and the export alike.
struct AteShareSlip: View {
    let receipt: AteReceipt

    var body: some View {
        VStack(alignment: .leading, spacing: AteMetrics.snug) {
            dishes
            AteDashedRule()
            placeLine
            signature
        }
        .padding(.top, AteShareSlipMetrics.top)
        .padding(.horizontal, AteShareSlipMetrics.inset)
        .padding(.bottom, AteShareSlipMetrics.bottom + AteMetrics.tornEdgeHeight)
        .frame(width: AteShareSlipMetrics.width)
        .ateSlip()
        .ateTornPaper(topRadius: AteShareSlipMetrics.radius)
        .accessibilityElement(children: .combine)
    }

    private var dishes: some View {
        VStack(alignment: .leading, spacing: AteMetrics.tight) {
            ForEach(receipt.items) { item in
                HStack(alignment: .firstTextBaseline, spacing: AteMetrics.regular) {
                    Text(item.name)
                        .ateText(.shareSlipDish)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if let score = item.score {
                        AteShareScore(score: score, isTop: item.id == topID)
                    }
                }
            }
        }
    }

    /// The best thing eaten: the first of the highest scores.
    private var topID: UUID? {
        receipt.items.filter { $0.score != nil }.max { ($0.score?.value ?? 0) < ($1.score?.value ?? 0) }?.id
    }

    @ViewBuilder
    private var placeLine: some View {
        if receipt.place.isEmpty == false {
            HStack(spacing: AteMetrics.tight) {
                Text(receipt.place)
                    .ateText(.shareSlipLabel)
                    .foregroundStyle(AtePalette.slip.fg)
                    .lineLimit(1)
                    .layoutPriority(1)
                if let locality = receipt.locality, locality.isEmpty == false {
                    Text(verbatim: "·")
                        .ateText(.shareSlipLabel)
                        .foregroundStyle(AtePalette.slip.muted)
                    Text(locality)
                        .ateText(.shareSlipLabel)
                        .foregroundStyle(AtePalette.slip.muted)
                        .lineLimit(1)
                }
            }
        }
    }

    private var signature: some View {
        HStack(alignment: .center) {
            Text(signatureLine)
                .ateText(.shareSlipLabel)
                .foregroundStyle(AtePalette.slip.fg)
                .lineLimit(1)
            Spacer(minLength: AteMetrics.snug)
            AteWordmark(height: AteShareSlipMetrics.wordmark)
        }
    }

    /// "@eamon", or "@eamon with @jess +1" — "with" muted.
    private var signatureLine: AttributedString {
        var line = AttributedString("@\(receipt.handle)")
        if let with = CompanionLine.compact(receipt.companions) {
            var word = AttributedString(" with ")
            word.foregroundColor = AtePalette.slip.muted
            line += word + AttributedString(with)
        }
        return line
    }
}

/// A score on the sticker: the numeral, and — for the top score — a butter mark behind it (the
/// score token's own colour, design rule 5: colour is punctuation).
struct AteShareScore: View {
    let score: Rating
    var isTop = false

    var body: some View {
        Text(ScoreFormat.halfStep(score.value))
            .ateText(.shareSlipScore)
            .monospacedDigit()
            .foregroundStyle(isTop ? ScoreStyle.of(score).ink : AtePalette.slip.fg)
            .padding(.horizontal, isTop ? AteShareSlipMetrics.markInset : 0)
            .padding(.vertical, isTop ? AteMetrics.hairspace : 0)
            .background {
                if isTop {
                    RoundedRectangle(cornerRadius: AteShareSlipMetrics.markRadius, style: .continuous)
                        .fill(ScoreStyle.of(score).fill)
                }
            }
            .fixedSize()
    }
}

/// **One dish's tag** — the sticker for the carousel habit (one photo per dish, a score on each,
/// Reels and TikTok): the name, its score in a butter capsule, and a small wordmark. White paper, a
/// capsule, so it reads as Ate's at any size. An unscored dish is its name alone.
struct AteDishTag: View {
    let name: String
    var score: Rating?

    var body: some View {
        HStack(spacing: AteMetrics.snug) {
            Text(name)
                .ateText(.shareTagName)
                .lineLimit(1)
                .foregroundStyle(AtePalette.slip.fg)
            if let score {
                Text(ScoreFormat.halfStep(score.value))
                    .ateText(.shareTagScore)
                    .monospacedDigit()
                    .foregroundStyle(ScoreStyle.of(score).ink)
                    .padding(.horizontal, AteShareSlipMetrics.markInset)
                    .padding(.vertical, AteMetrics.tight)
                    .background(Capsule().fill(ScoreStyle.of(score).fill))
            }
            AteWordmark(height: AteShareSlipMetrics.tagWordmark)
                .opacity(AteShareSlipMetrics.tagWordmarkOpacity)
        }
        .padding(.leading, AteShareSlipMetrics.tagInset)
        .padding(.trailing, AteShareSlipMetrics.tagInset - AteMetrics.tight)
        .padding(.vertical, AteMetrics.snug)
        .ateSlip()
        .background(Capsule().fill(AtePalette.slip.ground))
        .fixedSize()
        .accessibilityElement(children: .combine)
    }
}

enum AteShareSlipMetrics {
    /// The paper's width. Exported at 3× it is 600px — inside Meta's recommended sticker width and
    /// about two fifths of a story.
    static let width: CGFloat = 200
    static let inset: CGFloat = 14
    static let top: CGFloat = 16
    static let bottom: CGFloat = 12
    static let radius: CGFloat = 10
    static let wordmark: CGFloat = 12
    /// The butter mark behind the top score.
    static let markInset: CGFloat = 5
    static let markRadius: CGFloat = 4
    /// The dish tag.
    static let tagInset: CGFloat = 14
    static let tagWordmark: CGFloat = 9
    static let tagWordmarkOpacity: Double = 0.55
}

#if DEBUG
#Preview("Share slip") {
    VStack(spacing: AteMetrics.section) {
        AteShareSlip(receipt: .preview)
        AteShareSlip(receipt: .previewSingle)
        AteDishTag(name: "Tagliatelle al ragù", score: Rating(rounding: 4.5))
        AteDishTag(name: "Prawn spaghetti")
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .ateAccentGround(AteColor.coral)
}
#endif
