import AteKit
import SwiftUI

/// **The receipt** — what Ate prints from your words, and only that. The dishes lead in the title
/// face with dot leaders and their scores printed like prices (an unrated dish: the leader runs to
/// the edge); a dashed rule; the place and its address as mono fine print, never the title; a dashed
/// rule; order number and date, dish count and average; the handle and the wordmark; Edge B. Straight
/// once printed. **No barcode.** Dish rows and scores only, never a note under a line.
///
/// The existing ``ReceiptView``, without the barcode the contract cut on 3 Oct.
struct AteReceiptView: View {
    let receipt: AteReceipt
    /// Still being sorted: the dish lines are skeleton bars under the paper feed.
    var isPrinting = false
    var breathes = true
    /// A receipt that cannot print without a place: the place slot is the Place key.
    var onAddPlace: (() -> Void)?

    var body: some View {
        ReceiptView(
            receipt: receipt,
            isPrinting: isPrinting,
            breathes: breathes,
            onAddPlace: onAddPlace
        )
    }
}
