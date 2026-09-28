import AteKit
import SwiftUI

/// **The Top Ate** (round 8, `Main.dc.html`) — the week's eight best dishes, printed as a receipt:
/// numbered lines `01`…`08`, each the dish (the first a size up), its place in the fine print under
/// it, its score like a price and its bookmark; a dashed rule; the barcode and the wordmark; edge B.
///
/// It is a receipt because Ate printed it, so the numbers, the places and the scores are DM Mono
/// (design rule 4); the dishes are the title face, as on every receipt since round 5. A dish nobody
/// has scored prints no score (rule 7).
struct TopAteReceipt: View {
    let lines: [TopAteLine]
    let onDish: (FeedDish) -> Void
    let onSave: (FeedDish) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(lines.enumerated()), id: \.element.id) { index, line in
                TopAteLineRow(line: line, isLead: index == 0, onOpen: { onDish(line.dish) }, onSave: {
                    onSave(line.dish)
                })
                if index < lines.count - 1 {
                    TopAteMetrics.rule
                }
            }
            // `height:14px; border-top:1px dashed` — the rule, then the barcode row under it.
            TopAteMetrics.rule
                .padding(.bottom, TopAteMetrics.footGap - TopAteMetrics.ruleWidth)
            HStack(alignment: .bottom, spacing: AteMetrics.regular) {
                AteBarcode()
                AteWordmark(height: AteMetrics.wordmarkFooter)
            }
        }
        .padding(.top, TopAteMetrics.paddingTop)
        .padding(.horizontal, TopAteMetrics.paddingSide)
        .padding(.bottom, TopAteMetrics.paddingBottom + AteMetrics.tornEdgeHeight)
        .ateSlip()
        .ateTornPaper(topRadius: TopAteMetrics.corner)
        .padding(.horizontal, FeedEditionMetrics.cardMargin)
        .accessibilityIdentifier("feed.topAte")
    }
}

/// One line: `display:flex; align-items:flex-start; gap:10px; padding:11px 0`.
private struct TopAteLineRow: View {
    let line: TopAteLine
    let isLead: Bool
    let onOpen: () -> Void
    let onSave: () -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.atePalette) private var palette

    private var dishStyle: AteTextStyle { isLead ? .topAteLeadDish : .topAteDish }
    private var scoreStyle: AteTextStyle { isLead ? .topAteLeadScore : .topAteScore }

    var body: some View {
        HStack(alignment: .top, spacing: TopAteMetrics.lineGap) {
            Button(action: onOpen) {
                HStack(alignment: .top, spacing: TopAteMetrics.lineGap) {
                    Text(line.number)
                        .ateText(.topAteRank)
                        .monospacedDigit()
                        // The first rank is brick, the others muted — the 6's colour, for the top.
                        .foregroundStyle(isLead ? AteColor.brick : palette.muted)
                        .frame(width: TopAteMetrics.rankWidth, alignment: .leading)
                        .padding(.top, TopAteMetrics.rankTop)
                    VStack(alignment: .leading, spacing: TopAteMetrics.nameGap) {
                        Text(line.dish.name)
                            .ateTextExact(dishStyle)
                            .offset(y: -AteFont.exactBaselineDrop(for: dishStyle, dynamicTypeSize: dynamicTypeSize))
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                            .foregroundStyle(palette.fg)
                        Text(place)
                            .ateText(.topAtePlace)
                            .lineLimit(1)
                            .foregroundStyle(palette.muted)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    if let score = line.dish.score {
                        Text(ScoreFormat.average(score))
                            .ateText(scoreStyle)
                            .monospacedDigit()
                            .foregroundStyle(palette.fg)
                            .fixedSize()
                            .padding(.top, TopAteMetrics.scoreTop)
                    }
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("feed.topAte.dish")
            AteSaveButton(dishName: line.dish.name, isSaved: line.dish.isSaved, identifier: "feed.save", action: onSave)
                // `margin:-9px -10px 0 -4px`.
                .padding(.top, -9)
                .padding(.trailing, -10)
                .padding(.leading, -4)
        }
        .padding(.vertical, TopAteMetrics.linePadding)
    }

    /// "TIPO 00, CBD" — the place, then its suburb when there is one.
    private var place: String {
        [line.dish.restaurantName, line.dish.suburb].compactMap { $0 }.filter { $0.isEmpty == false }
            .joined(separator: ", ")
    }
}

/// The Top Ate while it is read: the paper, eight still lines at the lines' own rhythm, the foot.
struct TopAteSkeleton: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(0..<TopAteMetrics.skeletonLines, id: \.self) { index in
                HStack(spacing: TopAteMetrics.lineGap) {
                    AteSkeletonBar(width: 18, height: 10)
                    AteSkeletonBar(width: [168, 132, 150, 118][index % 4], height: 14)
                    Spacer(minLength: 0)
                    AteSkeletonBar(width: 26, height: 12)
                }
                .frame(height: TopAteMetrics.skeletonLine)
                if index < TopAteMetrics.skeletonLines - 1 { TopAteMetrics.rule }
            }
            TopAteMetrics.rule
                .padding(.bottom, TopAteMetrics.footGap - TopAteMetrics.ruleWidth)
            AteBarcode().opacity(0.12)
        }
        .padding(.top, TopAteMetrics.paddingTop)
        .padding(.horizontal, TopAteMetrics.paddingSide)
        .padding(.bottom, TopAteMetrics.paddingBottom + AteMetrics.tornEdgeHeight)
        .ateSlip()
        .ateTornPaper(topRadius: TopAteMetrics.corner)
        .padding(.horizontal, FeedEditionMetrics.cardMargin)
        .accessibilityHidden(true)
    }
}

enum TopAteMetrics {
    /// `border-radius:22px 22px 0 0; padding:18px 20px 16px`.
    static let corner: CGFloat = 22
    static let paddingTop: CGFloat = 18
    static let paddingSide: CGFloat = 20
    static let paddingBottom: CGFloat = 16
    /// A line: `gap:10px; padding:11px 0`; the rank `width:22px; padding-top:2px`, the score's 1, the
    /// dish and its place `gap:2px`.
    static let lineGap: CGFloat = 10
    static let linePadding: CGFloat = 11
    static let rankWidth: CGFloat = 22
    static let rankTop: CGFloat = 2
    static let scoreTop: CGFloat = 1
    static let nameGap: CGFloat = 2
    /// `border-bottom:1px dashed #D9D2C8`.
    static let ruleWidth: CGFloat = 1
    /// The rule over the barcode row is the top of a 14 block.
    static let footGap: CGFloat = 14
    static let skeletonLines = 8
    static let skeletonLine: CGFloat = 56

    static var rule: some View {
        AteDashedLine(dash: [3, 3], lineWidth: ruleWidth, colour: AteFeedColor.rule)
    }
}
