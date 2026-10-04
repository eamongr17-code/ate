import AteKit
import SwiftUI

/// **Share, from your own entry** — the printed receipt on its coral stage, the same picture the
/// composer prints, in a sheet: close top left, Share the ink pill at the foot, nothing else. Share waits for the
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
            AteSheetHeader(title: nil) { dismiss() }
            // The photos and the receipt, centred in the room between the corners and the foot.
            GeometryReader { room in
                ScrollView {
                    AtePrintedReceiptStage(receipt: receipt, photos: photos)
                        .padding(.vertical, AteMetrics.section)
                        .frame(maxWidth: .infinity, minHeight: room.size.height)
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("share.receipt")
                }
                .scrollBounceBehavior(.basedOnSize)
                .scrollIndicators(.hidden)
            }
            V2PrintedFoot(pill: .init(title: "Share", isEnabled: photosLoaded, identifier: "share.send", action: send))
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
