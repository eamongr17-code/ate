import AteKit
import SwiftUI
import UIKit

/// **Share, from your own entry** (11 Oct, approved): the ink share sheet (``V2ShareSheet``) over the
/// entry page, sized to its cards and row. One share surface in the app: what follows a review and
/// what this shows are the same sheet.
///
/// The photos are fetched before the row is live, so the card that leaves is the card on screen. A
/// review of several dishes also reads which photo is which dish, so each dish goes on its own.
struct V2ReceiptShareSheet: View {
    let receipt: AteReceipt
    /// The entry's photos.
    var photos: [EntryCard.Photo] = []
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
        .presentationDetents([.height(V2ShareSheetMetrics.sheetHeight(dishes: receipt.items.count)), .large])
        .presentationDragIndicator(.visible)
        .presentationBackground(AteColor.ink)
        .task {
            let photos = photos
            if receipt.items.count > 1, photos.isEmpty == false, let loadPairs {
                let tags = await loadPairs()
                dishPhotos = SharePhotoPairs.positions(
                    reviewIDs: receipt.items.map(\.id), photos: photos, tags: tags
                )
            }
            images = await SharePhotos.images(photos.compactMap { photo in
                URL(string: photo.url).map { (position: photo.position, photo: AtePhoto(url: $0)) }
            })
            withAnimation(reduceMotion ? nil : .easeOut(duration: V2ShareSheetMetrics.cardsIn)) { photoLoaded = true }
        }
    }
}
