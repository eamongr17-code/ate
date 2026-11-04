import AteKit
import SwiftUI
import UIKit

/// **Share, from your own entry** (11 Oct, approved): the ink share sheet (``V2ShareSheet``) over the
/// entry page, sized to its cards and row. One share surface in the app: what follows a review and
/// what this shows are the same sheet.
///
/// The photos are fetched before the row is live, so the card that leaves is the card on screen. A
/// review of several dishes also needs which photo is which dish, so each dish goes on its own: the
/// pairs the entry page already holds are used at once, and the fresh read runs beside the photo
/// fetch rather than before it (4 Nov, Eamon: the sheet sat empty, then the cards lurched in).
struct V2ReceiptShareSheet: View {
    let receipt: AteReceipt
    /// The entry's photos.
    var photos: [EntryCard.Photo] = []
    /// Which photo is which dish, as the entry page already holds it: the cards are made from these
    /// without waiting on the read below.
    var heldPairs: [String: [PhotoDishTag]] = [:]
    /// Which photo is which dish (`photo_dishes`), read once the sheet is up; only for several dishes.
    var loadPairs: (@MainActor @Sendable () async -> [String: [PhotoDishTag]])?
    var source: ReceiptShareSource = .entry
    let analytics: AnalyticsRecorder

    @State private var images: [Int: UIImage] = [:]
    @State private var dishPhotos: [UUID: [Int]] = [:]
    @State private var photoLoaded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        V2ShareSheet(
            receipt: receipt, photos: images, dishPhotos: dishPhotos, source: source, isLive: photoLoaded,
            printsFirst: false, analytics: analytics
        )
        .padding(.top, AteMetrics.section)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(AteColor.ink)
        .presentationDetents([.height(V2ShareSheetMetrics.sheetHeight), .large])
        .presentationDragIndicator(.visible)
        .presentationBackground(AteColor.ink)
        .task {
            let photos = photos
            let wantsPairs = receipt.items.count > 1 && photos.isEmpty == false
            let reviewIDs = receipt.items.map(\.id)
            func positions(_ tags: [String: [PhotoDishTag]]) -> [UUID: [Int]] {
                SharePhotoPairs.positions(reviewIDs: reviewIDs, photos: photos, tags: tags)
            }
            let reading: Task<[String: [PhotoDishTag]], Never>? = wantsPairs ? loadPairs.map { load in
                Task { await load() }
            } : nil
            if wantsPairs, heldPairs.isEmpty == false { dishPhotos = positions(heldPairs) }
            images = await SharePhotos.images(photos.compactMap { photo in
                URL(string: photo.url).map { (position: photo.position, photo: AtePhoto(url: $0)) }
            })
            // Nothing held: the cards wait for the read, so they come in once, already sorted.
            if heldPairs.isEmpty, let reading { dishPhotos = positions(await reading.value) }
            withAnimation(reduceMotion ? nil : V2ShareSheetMetrics.cardsIn) { photoLoaded = true }
            if heldPairs.isEmpty == false, let reading {
                let fresh = positions(await reading.value)
                if fresh != dishPhotos {
                    withAnimation(reduceMotion ? nil : V2ShareSheetMetrics.cardsIn) { dishPhotos = fresh }
                }
            }
        }
    }
}
