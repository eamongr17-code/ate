import AteKit
import SwiftUI
import UIKit

/// **Custom surface #3** — the receipt, as a composed artifact (design-language §4).
///
/// Three bands in fixed proportions on one 4:5 canvas, and the same view on screen and in the
/// exported image — a screenshot and a share that disagree would be the loop's worst bug.
///
/// What changed, and why: the old artifact opened with the *place*, which inverts the hierarchy
/// (score > dish > place > photo > provenance > footer); three elements competed to be "the score"
/// (numeral, stars, and the numeral again per line); and a `Spacer` left a void on the fixed-size
/// export that never appeared on screen. Bands fix all three at once — every element has exactly one
/// home and the proportions don't move with the content.
///
/// Its colours are the deliberately non-adaptive receipt tokens, and its type is the app's ONLY
/// fixed-size ramp: an image rendered at 1080×1350 must not be reflowed by the reader's Dynamic Type
/// setting (§7's documented exception).
struct ReceiptArtifact: View {
    let receipt: ReceiptModel
    var photoURL: (ReceiptModel.Line) -> URL?
    /// The export is a fixed 4:5 canvas; on screen the artifact sizes itself to the same ratio, so
    /// the two are the same composition at two scales.
    var isExport = false

    /// §9's question #3, judged at thumbnail size in a real message thread.
    @AppStorage(DesignDebugSettings.receiptBandOrderKey)
    private var bandOrderRaw = ReceiptBandOrder.designDefault.rawValue

    private var bandOrder: ReceiptBandOrder {
        #if DEBUG || BETA
        ReceiptBandOrder(rawValue: bandOrderRaw) ?? .designDefault
        #else
        .designDefault
        #endif
    }

    var body: some View {
        GeometryReader { geometry in
            let height = geometry.size.height
            VStack(spacing: 0) {
                switch bandOrder {
                case .mediaLed:
                    // A: the plate first. Reads as a photograph with a caption.
                    band(media, height * Self.mediaFraction)
                    band(statement, height * Self.statementFraction)
                    band(tag, height * Self.tagFraction)
                case .statementLed:
                    // B: the score first, with the media bleeding off the bottom edge. Reads as a
                    // poster — which is the better read at thumbnail size, and the worse one when
                    // the photo is the thing worth sharing.
                    band(statement, height * Self.statementFraction)
                    band(tag, height * Self.tagFraction)
                    band(media, height * Self.mediaFraction)
                }
            }
        }
        .aspectRatio(Self.canvasRatio, contentMode: .fit)
        .background(Theme.Color.receiptBackground)
    }

    /// A band is a fixed slice of the canvas, and the clip comes AFTER the height — the order is
    /// load-bearing. Clipping inside the band clips to its *intrinsic* size, which is exactly how a
    /// five-line statement ended up printed over the tag band on device.
    private func band(_ content: some View, _ height: CGFloat) -> some View {
        content
            .frame(height: height)
            .clipped()
    }

    // The proportions are the composition. They do not respond to how much text there is: a
    // two-line dish name must cost the dish name its second line, never the photo its height.
    private static let mediaFraction: CGFloat = 0.55
    private static let statementFraction: CGFloat = 0.35
    private static let tagFraction: CGFloat = 0.10
    private static let canvasRatio = Theme.Size.receiptExport.width / Theme.Size.receiptExport.height

    // MARK: - Band 1 · Media

    /// Bleeds to the edges it touches, with a straight edge where it meets the statement. Never a
    /// scrim and never text over it: the media is the picture, the statement is the words.
    private var media: some View {
        ReceiptMediaBand(receipt: receipt, photoURL: photoURL)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Band 2 · Statement

    @ViewBuilder
    private var statement: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.snug) {
            if let line = receipt.lines.first, receipt.isSingleDish {
                heroScore(line.score.value)
                Text(line.dishName)
                    .font(Theme.Text.receiptDishName)
                    .foregroundStyle(Theme.Color.receiptForeground)
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
                place
            } else {
                // §4: the restaurant takes the dish slot, and there is no hero numeral — a sitting
                // isn't a thing anyone rates. The suburb is dropped rather than given a line: the
                // band is 35% of a fixed canvas and the dishes are what it's for.
                Text(receipt.restaurantName)
                    .font(Theme.Text.receiptDishName)
                    .foregroundStyle(Theme.Color.receiptForeground)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                dishLines
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.horizontal, Theme.Spacing.loose)
        .padding(.vertical, Theme.Spacing.regular)
    }

    /// **The score, and nothing next to it.** The stars are gone from the single-dish receipt: a
    /// numeral this size already says 4.5, and a star row beside it was a second, quieter answer to
    /// the same question.
    private func heroScore(_ score: Double) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text(ScoreFormat.halfStep(score))
                .font(Theme.Text.receiptScoreNumeral)
            Text("/5")
                .font(Theme.Text.receiptScoreScale)
                .foregroundStyle(Theme.Color.receiptSecondary)
        }
        .foregroundStyle(Theme.Color.receiptForeground)
        .lineLimit(1)
        .minimumScaleFactor(0.6)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Rated \(ScoreFormat.outOfFive(score))")
    }

    /// Multi-dish: one line per dish, score right-aligned into a column. Half-steps, because each
    /// one is a single review — not an aggregate (§4's rule, tested in `ScoreFormatTests`).
    ///
    /// Capped, for the same reason the media band's mosaic is: the statement is 35% of a fixed
    /// canvas, so a nine-dish sitting has to resolve to a composition rather than to a list that
    /// runs off the bottom. What doesn't fit is COUNTED, never silently dropped.
    private var dishLines: some View {
        // The overflow line costs a row, so a sitting of five shows three dishes and "+2 more",
        // never four dishes and "+1" in five rows' worth of space.
        let hidden = max(0, receipt.lines.count - Self.maxDishRows)
        let visible = receipt.lines.prefix(hidden > 0 ? Self.maxDishRows - 1 : Self.maxDishRows)
        return VStack(alignment: .leading, spacing: Theme.Spacing.tight) {
            ForEach(visible) { line in
                dishLine(
                    name: line.dishName,
                    score: ScoreFormat.halfStep(line.score.value),
                    colour: Theme.Color.receiptForeground
                )
            }
            if hidden > 0 {
                dishLine(name: "+\(hidden + 1) more", score: "", colour: Theme.Color.receiptSecondary)
            }
        }
    }

    private func dishLine(name: String, score: String, colour: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.snug) {
            Text(name)
                .lineLimit(1)
            Spacer(minLength: Theme.Spacing.snug)
            Text(score)
        }
        .font(Theme.Text.receiptSecondary)
        .foregroundStyle(colour)
    }

    /// Three rows fit the 35% band under the restaurant name. A fourth is what printed straight
    /// through the tag band on device.
    private static let maxDishRows = 3

    /// The place line. Rule R (§5) survives here as an *invisible* difference: on screen it is a
    /// tappable link, in the export it is flat text — identical type, identical colour, identical
    /// pixels, so the shared image can't disagree with the screen. Only the tap (and its
    /// `restaurant_name_tapped`) exists on one side.
    @ViewBuilder
    private var place: some View {
        if !isExport, let restaurantID = receipt.restaurantID {
            RestaurantNameLink(
                name: receipt.restaurantName,
                suburb: receipt.suburb,
                restaurantID: restaurantID,
                from: .receipt,
                style: .inline,
                font: Theme.Text.receiptSecondary,
                foreground: Theme.Color.receiptSecondary
            )
        } else {
            Text(receipt.placeLine)
                .font(Theme.Text.receiptSecondary)
                .foregroundStyle(Theme.Color.receiptSecondary)
                .lineLimit(1)
        }
    }

    // MARK: - Band 3 · Tag

    /// ONE row under a hairline: who and when on the left, the app on the right. It was two stacked
    /// captions, which made the footer look like a second statement.
    private var tag: some View {
        VStack(spacing: 0) {
            Theme.Color.receiptRule
                .frame(height: Theme.Size.receiptRule)
            HStack(spacing: Theme.Spacing.snug) {
                if let author = receipt.author {
                    AvatarView(
                        url: author.avatarURLString.flatMap(URL.init(string:)),
                        size: Theme.Size.avatarByline
                    )
                    Text("\(author.handle) · \(dateText)")
                } else {
                    Text(dateText)
                }
                Spacer(minLength: Theme.Spacing.snug)
                Text("ate")
            }
            .font(Theme.Text.receiptFooter)
            .foregroundStyle(Theme.Color.receiptSecondary)
            .lineLimit(1)
            .frame(maxHeight: .infinity)
            .padding(.horizontal, Theme.Spacing.loose)
        }
    }

    private var dateText: String {
        receipt.date.formatted(.dateTime.day().month(.abbreviated).year())
    }
}

// MARK: - The media band

/// Band 1's content: a photo, the dish's own tile, or a deterministic mosaic of both.
///
/// **Always filled.** The receipt is the one surface where an absent zone is not an option — it is a
/// fixed canvas that leaves the device, so "no photo" has to be a *composition*, not a hole. An
/// imageless receipt is a typographic poster: the same `DishTileArtwork` a diary row uses, at band
/// scale.
struct ReceiptMediaBand: View {
    let receipt: ReceiptModel
    var photoURL: (ReceiptModel.Line) -> URL?

    var body: some View {
        let layout = ReceiptMosaic.layout(forItemCount: receipt.lines.count)
        let visible = Array(receipt.lines.prefix(ReceiptMosaic.visibleCount(for: layout)))

        mosaic(layout: layout, visible: visible)
            .background(Theme.Color.receiptBackground)
    }

    @ViewBuilder
    private func mosaic(layout: ReceiptMosaic.Layout, visible: [ReceiptModel.Line]) -> some View {
        switch layout {
        case .single:
            cell(visible.first)
        case .sideBySide:
            HStack(spacing: Self.cellGap) {
                cell(visible.first)
                cell(visible.dropFirst().first)
            }
        case .oneLargeTwoStacked:
            HStack(spacing: Self.cellGap) {
                cell(visible.first)
                VStack(spacing: Self.cellGap) {
                    cell(visible.dropFirst().first)
                    cell(visible.dropFirst(2).first)
                }
            }
        case .grid:
            VStack(spacing: Self.cellGap) {
                HStack(spacing: Self.cellGap) {
                    cell(visible.first)
                    cell(visible.dropFirst().first)
                }
                HStack(spacing: Self.cellGap) {
                    cell(visible.dropFirst(2).first)
                    cell(visible.dropFirst(3).first, badge: ReceiptMosaic.overflowBadge(for: layout))
                }
            }
        }
    }

    /// A sliver of the receipt's own ground between cells. Without it two typographic tiles are the
    /// same tone touching, and a mosaic reads as one band with strange text in it rather than as
    /// four dishes.
    private static let cellGap = Theme.Spacing.hairline

    /// One cell: the staged photo fill-cropped, or the dish's tile. The photo is read synchronously
    /// because `ImageRenderer` cannot wait for an async load — an export that raced the disk would
    /// ship blank cells.
    @ViewBuilder
    private func cell(_ line: ReceiptModel.Line?, badge: String? = nil) -> some View {
        GeometryReader { geometry in
            Group {
                if let line, let url = photoURL(line),
                   let image = UIImage(contentsOfFile: url.path(percentEncoded: false)) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else if let line {
                    DishTileArtwork(
                        dish: DishTileSubject(id: line.dishID, name: line.dishName),
                        // The type scales off the SHORT side, so a cell in a 2×2 grid gets smaller
                        // letters than a cell that owns the whole band — one rule, four sizes.
                        well: min(geometry.size.width, geometry.size.height)
                    )
                } else {
                    Theme.Color.surfaceTile
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
            .overlay(alignment: .bottomTrailing) { overflow(badge) }
        }
    }

    @ViewBuilder
    private func overflow(_ badge: String?) -> some View {
        if let badge {
            Text(badge)
                .font(Theme.Text.receiptDishName)
                .foregroundStyle(Theme.Color.receiptBackground)
                .padding(Theme.Spacing.snug)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // Heavy enough that the cell underneath reads as *covered* rather than as a tile
                // with a number printed on top of its letters, light enough that a photo still
                // shows through as the thing being counted.
                .background(Theme.Color.receiptForeground.opacity(0.75))
        }
    }
}

#Preview("Receipt — single dish, no photo") {
    ReceiptArtifact(
        receipt: ReceiptModel(
            restaurantName: "Chin Chin",
            suburb: "Melbourne",
            lines: [
                .init(id: UUID(), dishID: UUID(), dishName: "Prawn betel leaf", score: Rating(rounding: 4.5))
            ],
            author: .init(name: "Eamon", handle: "@eamon")
        ),
        photoURL: { _ in nil }
    )
    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.receipt))
    .padding(Theme.Spacing.gutter)
}

#Preview("Receipt — four dishes") {
    ReceiptArtifact(
        receipt: ReceiptModel(
            restaurantName: "Chin Chin",
            suburb: "Melbourne",
            lines: ["Prawn betel leaf", "Son-in-law eggs", "Kingfish sashimi", "Twice cooked beef"].map {
                .init(id: UUID(), dishID: UUID(), dishName: $0, score: Rating(rounding: 4))
            },
            author: .init(name: "Eamon", handle: "@eamon")
        ),
        photoURL: { _ in nil }
    )
    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.receipt))
    .padding(Theme.Spacing.gutter)
}
