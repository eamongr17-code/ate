import AteKit
import SwiftUI
import UIKit

/// What a list receipt prints. Data only, like ``AteReceipt``.
struct AteListReceiptContent: Equatable {
    struct Line: Equatable, Identifiable {
        let id: UUID
        let rank: Int
        let dish: String
        /// `nil` is unscored: no score, and the leader runs to the edge (never inferred).
        let score: Rating?
        /// The place, as fine print under the dish. Never assumed: absent prints nothing.
        let place: String?
    }

    let title: String
    /// The printed lines — ten at most.
    let lines: [Line]
    /// Every dish on the list, printed or not.
    let count: Int
    let date: Date
    let handle: String

    /// How many dishes did not fit: "+4 more".
    var more: Int { max(0, count - lines.count) }
}

/// **The list receipt** (`lists-notifications.html` C8, approved) — the receipt's own rules for a
/// ranking: the list's name as the head, a dashed rule, then each dish with its rank in mono, the dot
/// leader and its score printed like a price, its place in mono fine print beneath; past ten lines,
/// "+N more"; a dashed rule; the count and the date; "Judged by @handle" beside the wordmark; Edge B.
/// No order number, no average, no barcode: it is a ranking, not a bill.
struct AteListReceipt: View {
    let content: AteListReceiptContent

    var body: some View {
        VStack(alignment: .leading, spacing: AteListReceiptMetrics.gap) {
            Text(content.title)
                .ateText(.kitListReceiptTitle)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
            AteDashedRule()
            VStack(alignment: .leading, spacing: AteListReceiptMetrics.lineGap) {
                ForEach(content.lines) { line($0) }
                if content.more > 0 {
                    Text(verbatim: "+\(content.more) more")
                        .ateText(.kitListReceiptPlace)
                        .foregroundStyle(AtePalette.slip.muted)
                        .padding(.leading, AteListReceiptMetrics.placeIndent)
                }
            }
            AteDashedRule()
            HStack {
                Text(content.count == 1 ? "1 dish" : "\(content.count) dishes")
                Spacer(minLength: AteMetrics.snug)
                Text(content.date.formatted(AteReceipt.dateFormat))
            }
            .ateText(.kitListReceiptLabel)
            .foregroundStyle(AtePalette.slip.fg)
            HStack {
                signature
                    .ateText(.kitListReceiptLabel)
                    .foregroundStyle(AtePalette.slip.fg)
                    .lineLimit(1)
                Spacer(minLength: AteMetrics.snug)
                AteWordmark(height: AteMetrics.wordmarkFooter)
            }
        }
        .padding(.top, AteListReceiptMetrics.top)
        .padding(.horizontal, AteMetrics.slipPadding)
        .padding(.bottom, AteListReceiptMetrics.bottom + AteMetrics.tornEdgeHeight)
        .ateSlip()
        .ateTornPaper(topRadius: AteMetrics.receiptTop)
        .accessibilityElement(children: .combine)
    }

    /// `.rl`: rank, dish, leader, score on one baseline; `.rpl`: the place under the dish.
    private func line(_ line: AteListReceiptContent.Line) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: AteMetrics.snug) {
                Text(verbatim: "\(line.rank)")
                    .ateText(.kitListReceiptRank)
                    .foregroundStyle(AtePalette.slip.muted)
                    .frame(width: AteListReceiptMetrics.rankWidth, alignment: .leading)
                Text(line.dish)
                    .ateText(.kitListReceiptDish)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .layoutPriority(1)
                AteDotLeader()
                    .alignmentGuide(.firstTextBaseline) { $0[.bottom] + ReceiptLeadMetrics.leaderRise }
                if let score = line.score {
                    Text(ScoreFormat.halfStep(score.value))
                        .ateText(.kitListReceiptScore)
                        .monospacedDigit()
                        .fixedSize()
                        .layoutPriority(1)
                }
            }
            if let place = line.place {
                Text(place)
                    .ateText(.kitListReceiptPlace)
                    .foregroundStyle(AtePalette.slip.muted)
                    .lineLimit(1)
                    .padding(.leading, AteListReceiptMetrics.placeIndent)
                    .padding(.top, AteListReceiptMetrics.placeLift)
            }
        }
    }

    /// "Judged by @eamon" — "Judged by" muted.
    private var signature: Text {
        var judged = AttributedString("Judged by ")
        judged.foregroundColor = AtePalette.slip.muted
        return Text(judged + AttributedString("@\(content.handle)"))
    }
}

/// **The list receipt on its coral page** — the top three photos clear above the paper in a tilted
/// cluster (84, `-7 5 -3`), the paper 34 in from each side of the 390 page. One drawing for the
/// screen and the exported picture.
struct AteListReceiptStage: View {
    let content: AteListReceiptContent
    var photos: [AtePhoto] = []

    var body: some View {
        VStack(spacing: AteListReceiptMetrics.photoGap) {
            if photos.isEmpty == false {
                PhotoCluster(
                    photos: Array(photos.prefix(AteListReceiptMetrics.photos)),
                    side: AteListReceiptMetrics.photo,
                    surface: AteColor.coral,
                    topPadding: 0,
                    bottomPadding: 0,
                    angles: AteListReceiptMetrics.angles
                )
            }
            AteListReceipt(content: content)
                .padding(.horizontal, AteListReceiptMetrics.paperInset)
        }
        .frame(width: AteListReceiptMetrics.pageWidth)
        .environment(\.atePalette, .accent(AteColor.coral))
    }
}

/// **The list receipt as a picture** — the same stage, on coral (or, for an Instagram Stories
/// sticker, on nothing), light, at the default text size.
@MainActor
enum AteListReceiptImage {
    static func render(_ content: AteListReceiptContent, photos: [AtePhoto]) -> UIImage? {
        image(content, photos: photos, onCoral: true)
    }

    static func sticker(_ content: AteListReceiptContent, photos: [AtePhoto]) -> UIImage? {
        image(content, photos: photos, onCoral: false)
    }

    private static func image(_ content: AteListReceiptContent, photos: [AtePhoto], onCoral: Bool) -> UIImage? {
        let view = AteListReceiptStage(content: content, photos: photos)
            .padding(.vertical, AtePrintedReceiptMetrics.exportPadding)
            .background(onCoral ? AteColor.coral : .clear)
            .foregroundStyle(AteColor.ink)
            .environment(\.dynamicTypeSize, .large)
            .environment(\.colorScheme, .light)
            .environment(\.ateIsSnapshotting, true)
        let renderer = ImageRenderer(content: view)
        renderer.scale = AteMetrics.shareExportScale
        renderer.isOpaque = onCoral
        return renderer.uiImage
    }
}

enum AteListReceiptMetrics {
    /// `.receipt{padding:22px 16px 14px; gap:9px}`; the lines `gap:7px`.
    static let top: CGFloat = 22
    static let bottom: CGFloat = 14
    static let gap: CGFloat = 9
    static let lineGap: CGFloat = 7
    /// `.rl .q{width:16px}`; `.rpl{padding-left:24px; margin-top:-3px}`.
    static let rankWidth: CGFloat = 16
    static let placeIndent: CGFloat = 24
    static let placeLift: CGFloat = -3
    /// The page: 390 wide, the paper `margin:24px 34px 0` under the cluster.
    static let pageWidth: CGFloat = 390
    static let paperInset: CGFloat = 34
    static let photoGap: CGFloat = 24
    /// `.ph-img{width:84px; border-radius:24px}`, `rotate(-7 5 -3)`.
    static let photo: CGFloat = 84
    static let photos = 3
    static let angles: [Double] = [-7, 5, -3]
    /// Ten lines at most; past ten, "+N more".
    static let lineLimit = 10
}

#if DEBUG || BETA
extension AteListReceiptContent {
    /// The design's own burgers (`lists-notifications.html` C8).
    static let preview: AteListReceiptContent = {
        let dishes = ["Double cheeseburger", "Smash burger", "The Easey", "Cheeseburger", "Fried chicken burger",
                      "Mushroom burger"]
        let places = ["Butchers Diner", "Royal Stacks", "Easey\u{2019}s", "Andrew\u{2019}s Burgers",
                      "Belles Hot Chicken", "Lord of the Fries"]
        let scores: [Double] = [5, 4.5, 4.5, 4, 4, 3.5]
        return AteListReceiptContent(
            title: "Melbourne\u{2019}s best burgers",
            lines: dishes.indices.map { index in
                Line(id: UUID(), rank: index + 1, dish: dishes[index], score: Rating(exactly: scores[index]),
                     place: places[index])
            },
            count: dishes.count,
            date: Date(timeIntervalSince1970: 1_791_158_400),
            handle: "eamon"
        )
    }()
}
#endif
