import AteKit
import SwiftUI

/// **The receipt** (10 Oct, Eamon: one receipt, "simplify it a bit… it needs to look good in a small
/// space"): what prints after a review, what the entry page shares, and what is stuck on a photo.
/// Dish left in the heading voice; every score a star and its number in one fixed column, tabular
/// digits, so nothing hangs off anything (a 5.0 filled butter and a 6 brick, the rest bare ink; an
/// unscored dish an empty slot, never a number — scores are never inferred); one dashed rule; the
/// place, and its suburb on the line under it (never the street, never cut); the signature and the
/// wordmark. No order number, date, count or average.
///
/// **Printing** (the Summary while the sorter works): skeleton bars where the dishes will be, under
/// the paper feed. A receipt that cannot print without a place carries the Place key where the place
/// prints.
///
/// One drawing at one width (``AteShareSlipMetrics/width``): on screen it is scaled up as a whole
/// (``AtePrintedReceiptStage``); exported at 3× it is the sticker.
struct AteShareSlip: View {
    let receipt: AteReceipt
    /// Still being sorted: the dish lines are skeleton bars.
    var isPrinting = false
    /// …and whether the bars carry the feed. It stops once the wait is over.
    var breathes = true
    /// A receipt that cannot print without a place: the place slot is the Place key.
    var onAddPlace: (() -> Void)?
    /// Your own printed receipt (10 Oct, approved): a tap on a dish name opens "Which dish?" to fix
    /// it. Nothing on the paper says so; the line darkens under the finger like any tappable row.
    var onFixDish: ((AteReceipt.Item) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: AteMetrics.snug) {
            if isPrinting {
                ShareSlipSkeleton(breathes: breathes)
            } else {
                dishes
            }
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
        .accessibilityElement(children: onFixDish == nil ? .combine : .contain)
    }

    private var dishes: some View {
        VStack(alignment: .leading, spacing: AteMetrics.tight) {
            ForEach(receipt.items) { item in
                HStack(alignment: .top, spacing: AteMetrics.regular) {
                    dishName(item)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    AteShareScore(score: item.score)
                }
            }
        }
    }

    @ViewBuilder
    private func dishName(_ item: AteReceipt.Item) -> some View {
        let name = Text(item.name)
            .ateText(.shareSlipDish)
            // A long name wraps, then sets down a little, before it is ever cut off: the receipt is
            // shared, and "Spanner crab spa…" says nothing.
            .lineLimit(3)
            .minimumScaleFactor(0.75)
            .fixedSize(horizontal: false, vertical: true)
        if let onFixDish {
            Button { onFixDish(item) } label: { name }
                .buttonStyle(ShareSlipNameStyle())
                .accessibilityIdentifier("receipt.dish")
        } else {
            name
        }
    }

    @ViewBuilder
    private var placeLine: some View {
        if receipt.place.isEmpty == false {
            // The place on its line, the suburb on the next (11 Oct, Eamon: "the suburb getting cut
            // off… can't happen"). Either wraps before it is ever cut.
            VStack(alignment: .leading, spacing: 0) {
                Text(receipt.place)
                    .ateText(.shareSlipLabel)
                    .foregroundStyle(AtePalette.slip.fg)
                    .fixedSize(horizontal: false, vertical: true)
                if let locality = receipt.locality, locality.isEmpty == false {
                    Text(locality)
                        .ateText(.shareSlipLabel)
                        .foregroundStyle(AtePalette.slip.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else if let onAddPlace {
            ComposerKey(
                title: "Place",
                icon: .place,
                iconSize: AteShareSlipMetrics.placeKeyIcon,
                background: AtePalette.slip.field,
                foreground: AtePalette.slip.fg,
                identifier: "summary.place",
                action: onAddPlace
            )
            .frame(maxWidth: .infinity)
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

/// A score in the receipt's column: a star, then the number (11 Oct, Eamon: "no one is gonna know
/// what 3.5 is"). Every score has the same slot, so the numbers stack. Only a perfect 5.0 (butter)
/// and the secret 6 (brick, white) are filled, in the score token's own colours; every other score
/// is bare ink on the paper. No score at all leaves the slot empty: scores are never inferred.
struct AteShareScore: View {
    let score: Rating?

    /// Filled only for the two scores that mean something more.
    private var isFilled: Bool { score.map { $0.isPerfect || $0.isBlownAway } ?? false }

    var body: some View {
        ZStack {
            if let score {
                let ink = isFilled ? ScoreStyle.of(score).ink : AtePalette.slip.fg
                HStack(spacing: AteShareSlipMetrics.starGap) {
                    AteIcon.starFilled.view(size: AteShareSlipMetrics.star)
                    Text(ScoreFormat.halfStep(score.value))
                        .ateText(.shareSlipScore)
                        .monospacedDigit()
                }
                .foregroundStyle(ink)
            }
        }
        .frame(width: AteShareSlipMetrics.scoreColumn, height: AteShareSlipMetrics.scoreBox)
        .background {
            if let score, isFilled {
                RoundedRectangle(cornerRadius: AteShareSlipMetrics.markRadius, style: .continuous)
                    .fill(ScoreStyle.of(score).fill)
            }
        }
        .padding(.top, AteShareSlipMetrics.scoreLift)
        .accessibilityLabel(score.map { "\(ScoreFormat.halfStep($0.value)) stars" } ?? "No score")
    }
}

/// A dish name you can fix: the slip's own ink, and a faint plate behind it while it is held.
private struct ShareSlipNameStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(AtePalette.slip.fg)
            .background {
                RoundedRectangle(cornerRadius: AteShareSlipMetrics.markRadius, style: .continuous)
                    .fill(AtePalette.slip.fg.opacity(configuration.isPressed ? AteShareSlipMetrics.pressedOpacity : 0))
                    .padding(.horizontal, -AteShareSlipMetrics.pressedReach)
                    .padding(.vertical, -AteShareSlipMetrics.pressedReach / 2)
            }
            .contentShape(Rectangle())
    }
}

/// The dishes while they are being sorted: three rows at the dish lines' own height, the name and
/// the score box as blank bars, the third unscored — an unrated dish is an empty slot even before it
/// has a name.
private struct ShareSlipSkeleton: View {
    var breathes: Bool

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private static let rows: [(name: CGFloat, scored: Bool)] = [(118, true), (72, true), (98, false)]

    var body: some View {
        VStack(alignment: .leading, spacing: AteMetrics.tight) {
            ForEach(Array(Self.rows.enumerated()), id: \.offset) { _, row in
                HStack(alignment: .top, spacing: AteMetrics.regular) {
                    Capsule()
                        .fill(AtePalette.slip.fg.opacity(AteShareSlipMetrics.skeletonOpacity))
                        .frame(width: row.name, height: AteShareSlipMetrics.skeletonBar)
                        .padding(.top, (AteShareSlipMetrics.scoreBox - AteShareSlipMetrics.skeletonBar) / 2)
                    Spacer(minLength: 0)
                    RoundedRectangle(cornerRadius: AteShareSlipMetrics.markRadius, style: .continuous)
                        .fill(AtePalette.slip.fg.opacity(row.scored ? AteShareSlipMetrics.skeletonOpacity : 0))
                        .frame(width: AteShareSlipMetrics.scoreColumn, height: AteShareSlipMetrics.scoreBox)
                }
                .frame(height: AteTextStyle.shareSlipDish.lineBox(dynamicTypeSize), alignment: .top)
            }
        }
        .ateSkeletonSweep(breathes)
        .accessibilityHidden(true)
    }
}

enum AteShareSlipMetrics {
    /// The paper's width. On screen it runs 38 from each edge (``AtePrintedReceiptStage``); exported
    /// at 3× it is 600px — inside Meta's recommended sticker width and about two fifths of a story.
    static let width: CGFloat = 200
    static let inset: CGFloat = 14
    static let top: CGFloat = 16
    static let bottom: CGFloat = 12
    static let radius: CGFloat = 10
    static let wordmark: CGFloat = 12
    /// The score column: every slot the same width and height, so the numbers stack. Wide enough for
    /// the star and "4.5".
    static let scoreColumn: CGFloat = 48
    static let scoreBox: CGFloat = 24
    /// The star before every score, and the air between it and the number.
    static let star: CGFloat = 11
    static let starGap: CGFloat = 2
    static let markRadius: CGFloat = 5
    /// A dish name held under a finger: how dark its plate, and how far past the words it reaches.
    static let pressedOpacity: Double = 0.08
    static let pressedReach: CGFloat = 4
    /// The box sits a hair below the dish's cap height.
    static let scoreLift: CGFloat = 1
    static let placeKeyIcon: CGFloat = 16
    static let skeletonBar: CGFloat = 10
    static let skeletonOpacity: Double = 0.10
}

#if DEBUG
#Preview("Receipt") {
    VStack(spacing: AteMetrics.section) {
        AteShareSlip(receipt: .preview)
        AteShareSlip(receipt: .previewSingle)
        AteShareSlip(receipt: .preview, isPrinting: true)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .ateAccentGround(AteColor.coral)
}
#endif
