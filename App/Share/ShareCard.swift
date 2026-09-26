import AteKit
import SwiftUI

/// **What Ate prints, and what leaves the app.** The coral card from `Share.dc.html`: two tilted
/// photos behind a receipt tilted the other way (design rule 6 — the mess is tilt and overlap, in a
/// small static cluster).
///
/// This is *one* view, drawn once, and both the screen and the exported PNG are it — the artefact a
/// person sees before they send it and the artefact that arrives cannot be two drawings, or they
/// will disagree the first time either is edited.
struct ShareCard: View {
    let artefact: ShareArtefact
    /// The photos behind the paper, already resolved to images — ``ImageRenderer`` snapshots
    /// synchronously and would capture an `AsyncImage`'s placeholder.
    var photos: [AtePhoto] = []
    /// The Summary while the sorter works: the receipt prints what is known and leaves skeleton
    /// lines for the rest (`SummaryLoading`). Never set on an export — only a printed receipt leaves.
    var isPrinting = false
    var breathes = true

    /// `margin:30px 52px 0` — the card's side inset on the 390pt page.
    static let inset: CGFloat = 52
    /// …and what that leaves for the paper.
    static let width: CGFloat = 390 - inset * 2

    var body: some View {
        receipt
            .frame(width: Self.width)
            // `transform:rotate(-3deg)` — on the paper, not on the photos' container, so the
            // overlaid photos keep the artboard's own angles rather than compounding.
            .rotationEffect(.degrees(-3))
            // **Behind** the paper, not over it. The artboard's photos are absolute siblings the
            // `.slipwrap` paints on top of, which is what makes the receipt read as laid *on* the
            // pile rather than punched through it.
            .background(alignment: .topTrailing) { first }
            .background(alignment: .bottomLeading) { second }
    }

    // MARK: - Paper

    @ViewBuilder
    private var receipt: some View {
        switch artefact {
        case .entry(let receipt, _):
            ReceiptView(receipt: receipt, isPrinting: isPrinting, breathes: breathes)
        case .statement(let statement, let handle):
            StatementReceiptView(statement: statement, handle: handle)
        }
    }

    // MARK: - The mess

    /// `top:-30px; right:-36px`, 128 square, `rotate(12deg)`.
    @ViewBuilder
    private var first: some View {
        if let photo = photos.first {
            tile(photo, side: 128, angle: 12)
                .offset(x: 36, y: -30)
        }
    }

    /// `bottom:30px; left:-40px`, 112 square, `rotate(-14deg)`.
    @ViewBuilder
    private var second: some View {
        if photos.count > 1 {
            tile(photos[1], side: 112, angle: -14)
                .offset(x: -40, y: -30)
        }
    }

    private func tile(_ photo: AtePhoto, side: CGFloat, angle: Double) -> some View {
        AtePhotoTile(photo: photo, side: side, ring: AteColor.coral)
            .rotationEffect(.degrees(angle))
    }
}

/// What a share card is a picture of. Two artefacts, one layout: an entry's receipt with its photos,
/// or a month's statement, which has no photos because a statement is a total, not a meal.
enum ShareArtefact: Equatable {
    case entry(AteReceipt, photos: [URL])
    case statement(MonthlyStatement, handle: String)

    /// Which entry left the app, for `receipt_shared`. A statement has none.
    var entryID: UUID? {
        switch self {
        case .entry(let receipt, _): receipt.id
        case .statement: nil
        }
    }

    /// The photos behind the paper — two at most, as the artboard draws.
    var photoURLs: [URL] {
        switch self {
        case .entry(_, let photos): Array(photos.prefix(2))
        case .statement: []
        }
    }

    /// What the system share sheet announces the picture as.
    var exportName: String {
        switch self {
        case .entry(let receipt, _): "\(receipt.place) — Ate"
        case .statement(let statement, _): "\(statement.month.title) — Ate"
        }
    }
}

#if DEBUG
#Preview("Share card") {
    ShareCard(artefact: .entry(.preview, photos: []), photos: AtePhoto.swatches)
        .padding(.horizontal, ShareCard.inset)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ateAccentGround(AteColor.coral)
}
#endif
