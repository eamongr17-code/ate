import AteKit
import SwiftUI
import UIKit

/// **Share: the list receipt** (`lists-notifications.html` C8) — a sheet on the coral share ground:
/// close top left, Share top right, and the receipt with its top three photos clear above the paper.
/// Share waits for the photos, so the picture that leaves is the one on screen; it goes through the
/// app's one share pipeline (``ShareSheet``, Instagram Stories beside the system's destinations) and
/// is counted when it actually leaves.
struct ListShareSheet: View {
    let content: AteListReceiptContent
    let photoURLs: [URL]
    let analytics: AnalyticsRecorder

    @State private var photos: [AtePhoto] = []
    @State private var photosLoaded = false
    @State private var sending: ShareSender.Sending?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            AteSheetHeader(
                title: nil,
                primary: AteSheetPrimary(icon: .share, label: "Share", isEnabled: photosLoaded, action: send)
            ) { dismiss() }
            GeometryReader { room in
                ScrollView {
                    AteScaledLayout(scale: scale) {
                        AteListReceiptStage(content: content, photos: photos)
                            .scaleEffect(scale)
                    }
                    .padding(.vertical, AteMetrics.section)
                    .frame(maxWidth: .infinity, minHeight: room.size.height)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("list.receipt")
                }
                .scrollBounceBehavior(.basedOnSize)
                .scrollIndicators(.hidden)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .ateAccentGround(AteColor.coral)
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .task {
            photos = await ListSharePhotos.resolve(photoURLs)
            photosLoaded = true
        }
        .sheet(item: $sending) { sending in
            ShareSheet(sending: sending) { _ in
                analytics(ListEvents.shared(lines: content.lines.count))
            }
        }
    }

    /// The 390 page, fitted to this screen's width.
    private var scale: CGFloat { AteScreen.width / AteListReceiptMetrics.pageWidth }

    /// Render, and hand it to the system. A render that fails opens nothing and is felt.
    private func send() {
        guard let image = AteListReceiptImage.render(content, photos: photos) else {
            AteHaptics.refused()
            return
        }
        sending = ShareSender.Sending(image: image, sticker: AteListReceiptImage.sticker(content, photos: photos))
    }
}

/// The list's top three photos, fetched before the receipt is drawn — an `AsyncImage` inside a
/// renderer captures its placeholder (``SharePhotos``, at the list receipt's three).
enum ListSharePhotos {
    @MainActor
    static func resolve(_ urls: [URL]) async -> [AtePhoto] {
        var resolved: [AtePhoto] = []
        for url in urls.prefix(AteListReceiptMetrics.photos) {
            guard let scheme = url.scheme, scheme == "http" || scheme == "https" else {
                resolved.append(AtePhoto(url: url))
                continue
            }
            guard let (data, _) = try? await URLSession.shared.data(from: url),
                  let image = UIImage(data: data) else { continue }
            resolved.append(AtePhoto(image: Image(uiImage: image)))
        }
        return resolved
    }
}
