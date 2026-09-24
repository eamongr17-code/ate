import AteKit
import SwiftUI
import UIKit

/// **`Share`** — the coral screen an artefact is sent from.
///
/// Done, the card, and one ink pill. The card is ``ShareCard``, which is also exactly what is
/// rendered to a PNG, so what a person approves and what lands in the thread are the same picture
/// (`Share.dc.html`). Colour is punctuation: the coral ground is the one place the app shouts, and
/// it shouts at the moment the receipt leaves.
struct ShareScreen: View {
    let artefact: ShareArtefact
    /// Where the share began — the entry page, an actions sheet, a statement. The north-star event's
    /// most interesting parameter.
    let source: ReceiptShareSource
    let analytics: AnalyticsRecorder

    @State private var photos: [AtePhoto] = []
    @State private var sending: SendingImage?
    @Environment(\.dismiss) private var dismiss

    /// The rendered picture — `Identifiable` so it can present the system sheet.
    private struct SendingImage: Identifiable {
        let id = UUID()
        let image: UIImage
    }

    var body: some View {
        VStack(spacing: 0) {
            doneRow
            ShareCard(artefact: artefact, photos: photos)
                .padding(.horizontal, ShareCard.inset)
                .padding(.top, ShareScreen.cardTop)
            Spacer(minLength: AteMetrics.section)
            AteButton(icon: .share, title: "Share", action: send)
                .padding(.horizontal, AteMetrics.gutter)
                .padding(.bottom, ShareScreen.buttonBottom)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .ateAccentGround(AteColor.coral)
        .task {
            photos = await SharePhotos.resolve(artefact.photoURLs)
            #if DEBUG
            dumpForDriveIfRequested()
            #endif
        }
        .sheet(item: $sending) { sending in
            ShareSheet(items: [sending.image])
        }
    }

    /// `margin:30px …` under the Done row.
    private static let cardTop: CGFloat = 30
    /// `bottom:40px`.
    private static let buttonBottom: CGFloat = 40

    /// `padding:60px 12px 0`, the one word on this screen, right-aligned. Text rather than an icon:
    /// it is a dismissal, and design rule 1's "icons before labels" is about *actions*.
    private var doneRow: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            Button("Done") { dismiss() }
                .ateText(.rowTitle)
                .foregroundStyle(AteColor.ink)
                .padding(.horizontal, AteMetrics.regular)
                .frame(height: AteMetrics.hit)
                .accessibilityIdentifier("share.done")
        }
        .padding(.horizontal, AteMetrics.regular)
        .ateContentTop()
    }

    #if DEBUG
    /// `-ate-dump-share`: writes the exported PNG into the app container so a drive can look at the
    /// thing that actually leaves. A simulator cannot be tapped from a shell, and the export is the
    /// one part of this screen that is not on screen.
    private func dumpForDriveIfRequested() {
        guard ProcessInfo.processInfo.arguments.contains("-ate-dump-share"),
              let image = ShareImage.render(artefact: artefact, photos: photos),
              let data = image.pngData(),
              let documents = FileManager.default.urls(
                for: .documentDirectory, in: .userDomainMask
              ).first
        else { return }
        try? data.write(to: documents.appending(path: "share-export.png"), options: .atomic)
    }
    #endif

    /// Render, count it, and hand it to the system. The event fires here — at the tap that sends it
    /// — not when this screen opened: looking at a receipt is not sharing one.
    private func send() {
        guard let image = ShareImage.render(artefact: artefact, photos: photos) else { return }
        analytics(EntryEvents.receiptShared(entryID: artefact.entryID, source: source))
        sending = SendingImage(image: image)
    }
}

/// Turning the photo URLs behind a receipt into something ``ImageRenderer`` can actually draw.
///
/// An `AsyncImage` inside a renderer captures its placeholder, so the two photos are fetched *before*
/// the card is drawn — on screen and in the export alike, which is what makes the two identical.
enum SharePhotos {
    @MainActor
    static func resolve(_ urls: [URL]) async -> [AtePhoto] {
        var resolved: [AtePhoto] = []
        for url in urls.prefix(2) {
            guard let scheme = url.scheme, scheme == "http" || scheme == "https" else {
                // A bundled fixture (`asset://`, `preview://`) — ``AtePhotoContent`` draws those
                // synchronously, so the renderer sees a real picture without a round trip.
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

#if DEBUG
#Preview("Share") {
    ShareScreen(
        artefact: .entry(.preview, photos: []),
        source: .entry,
        analytics: { _ in }
    )
}
#endif
