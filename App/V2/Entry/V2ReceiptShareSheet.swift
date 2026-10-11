import AteKit
import SwiftUI

/// **Share, from your own entry** (10 Oct, approved): the Printed screen again, as a sheet — close
/// top left, the receipt large on the coral ground across its first photo, and the row of ways out
/// at the foot (``V2ReceiptShareRow``). One receipt and one share surface in the app: what prints
/// after a review and what this shows are the same drawing.
///
/// The photos are fetched before the row is live, so the page that leaves is the page on screen.
struct V2ReceiptShareSheet: View {
    let receipt: AteReceipt
    /// The entry's photos, in order — fetched here.
    var photoURLs: [URL] = []
    var source: ReceiptShareSource = .entry
    let analytics: AnalyticsRecorder

    @State private var photos: [AtePhoto] = []
    @State private var photosLoaded = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            AteSheetHeader(title: receipt.shareTitle) { dismiss() }
            GeometryReader { room in
                ScrollView {
                    AtePrintedReceiptStage(
                        receipt: receipt, photos: photos, room: room.size.height - 2 * AteMetrics.section
                    )
                        .padding(.vertical, AteMetrics.section)
                        .frame(maxWidth: .infinity, minHeight: room.size.height)
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("share.receipt")
                }
                .scrollBounceBehavior(.basedOnSize)
                .scrollIndicators(.hidden)
            }
            V2ReceiptShareRow(
                receipt: receipt, photos: photos, source: source, isEnabled: photosLoaded, analytics: analytics
            )
            .padding(.horizontal, AteMetrics.gutter)
            .padding(.top, AteMetrics.section)
            .padding(.bottom, AteSheetScaffoldMetrics.bareBottom)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .ateAccentGround(AteColor.coral)
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .task {
            photos = await SharePhotos.resolve(photoURLs)
            photosLoaded = true
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("share.sheet")
        // Its own viewer: the entry page's sits under this sheet, so a tapped photo waited there and
        // opened only once the sheet was closed (build 110).
        .atePhotoViewerHost()
    }
}
