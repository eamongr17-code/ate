import AteKit
import SwiftUI
import UIKit

/// **Share, from your own entry** (11 Oct, approved): the ink share sheet (``V2ShareSheet``) over the
/// entry page, sized to its cards and row. One share surface in the app: what follows a review and
/// what this shows are the same sheet.
///
/// The first photo is fetched before the row is live, so the card that leaves is the card on screen.
struct V2ReceiptShareSheet: View {
    let receipt: AteReceipt
    /// The entry's photos, in order. The first goes on the cards.
    var photoURLs: [URL] = []
    var source: ReceiptShareSource = .entry
    let analytics: AnalyticsRecorder

    @State private var photo: UIImage?
    @State private var photoLoaded = false

    var body: some View {
        V2ShareSheet(
            receipt: receipt, photo: photo, source: source, isLive: photoLoaded, analytics: analytics
        )
        .padding(.top, AteMetrics.section)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(AteColor.ink)
        .presentationDetents([.height(V2ShareSheetMetrics.sheetHeight), .large])
        .presentationDragIndicator(.visible)
        .presentationBackground(AteColor.ink)
        .task {
            photo = await SharePhotos.image(photoURLs.first)
            photoLoaded = true
        }
    }
}
