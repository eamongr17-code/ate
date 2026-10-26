import AteKit
import SwiftUI

/// **One receipt the share sheet can send** (23 Oct, Eamon, option B of `share-per-dish.html`): a
/// review of several dishes shares one dish at a time, its own one-line receipt on its own photo. The
/// whole receipt stays, as a sticker only: on one photo it would say the photo is every dish.
struct ShareReceiptPage: Identifiable, Equatable {
    /// The dish's line, or the entry for the whole receipt.
    let id: UUID
    /// The same receipt (same entry, so the same link and count), with only this dish's line.
    let receipt: AteReceipt
    /// The photos it can go on, as positions in the entry's photos, in order.
    let photos: [Int]
    let isWhole: Bool

    /// A page per dish, then the whole receipt; for one dish, the whole receipt alone. `available` is
    /// the photos in hand; `dishPhotos` each dish's own (``SharePhotoPairs``). Until the match has
    /// answered a dish has no photo (sticker only), and its story and post join when it lands.
    static func pages(for receipt: AteReceipt, available: [Int], dishPhotos: [UUID: [Int]]) -> [ShareReceiptPage] {
        let whole = ShareReceiptPage(
            id: receipt.id, receipt: receipt,
            photos: wholePhotos(receipt, available: available, dishPhotos: dishPhotos), isWhole: true
        )
        guard receipt.items.count > 1 else { return [whole] }
        let dishes = receipt.items.map { item in
            var one = receipt
            one.items = [item]
            let photos = (dishPhotos[item.id] ?? []).filter { available.contains($0) }
            return ShareReceiptPage(id: item.id, receipt: one, photos: photos, isWhole: false)
        }
        return dishes + [whole]
    }

    /// The whole receipt goes on any of the entry's photos, the best dish's first (25 Oct, Eamon:
    /// "default to showing the highest rated dish as the photo"): dishes by score, a tie in the
    /// receipt's order, unscored last; then any photo no dish has.
    static func wholePhotos(_ receipt: AteReceipt, available: [Int], dishPhotos: [UUID: [Int]]) -> [Int] {
        guard receipt.items.count > 1 else { return available }
        let ranked = receipt.items.enumerated().sorted { lhs, rhs in
            let left = lhs.element.score?.halfSteps ?? 0
            let right = rhs.element.score?.halfSteps ?? 0
            return left != right ? left > right : lhs.offset < rhs.offset
        }
        var order: [Int] = []
        for (_, item) in ranked {
            let own = (dishPhotos[item.id] ?? []).filter { available.contains($0) }
            order += own.filter { order.contains($0) == false }
        }
        return order + available.filter { order.contains($0) == false }
    }
}

/// One card in the carousel: a format, of one page.
struct ShareSlot: Hashable, Identifiable {
    let format: AteShareFormat
    let page: UUID

    var id: Self { self }
}
