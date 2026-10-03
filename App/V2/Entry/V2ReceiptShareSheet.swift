import AteKit
import SwiftUI

/// **Share, from your own entry** — the printed receipt on its coral stage, the same picture the
/// composer prints, in a sheet: close top left, Share top right, nothing else. Share waits for the
/// photos above the paper to load, so the picture that leaves is the one on screen.
struct V2ReceiptShareSheet: View {
    let receipt: AteReceipt
    let photoURLs: [URL]
    let analytics: AnalyticsRecorder

    @State private var photos: [AtePhoto] = []
    @State private var photosLoaded = false
    @State private var sender = V2ReceiptSender()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            AteSheetHeader(
                title: nil,
                primary: AteSheetPrimary(icon: .share, label: "Share", isEnabled: photosLoaded, action: send)
            ) {
                dismiss()
            }
            ScrollView {
                AtePrintedReceiptStage(receipt: receipt, photos: photos)
                    .padding(.vertical, AteMetrics.section)
                    .frame(maxWidth: .infinity)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("share.receipt")
            }
            .scrollBounceBehavior(.basedOnSize)
            .scrollIndicators(.hidden)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .ateAccentGround(AteColor.coral)
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .task {
            photos = await SharePhotos.resolve(photoURLs)
            photosLoaded = true
        }
        .sheet(item: $sender.sending) { sending in
            ShareSheet(sending: sending) { destination in
                analytics(EntryEvents.receiptShared(
                    entryID: receipt.id,
                    source: destination == .instagramStories ? .instagramStories : .entry
                ))
            }
        }
    }

    private func send() {
        sender.send(receipt, photos: photos)
    }
}
