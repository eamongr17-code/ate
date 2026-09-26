import AteKit
import SwiftUI
import UIKit

/// **`Share`** — the coral screen an artefact is sent from.
///
/// The receipt as the hero, and two pills at the foot: **Done** (white, secondary) and **Share**
/// (ink, primary) — the layout `SummaryFinal.dc.html` gives the moment after Done in the composer,
/// and the one every share uses, so the same action looks and behaves the same wherever it starts
/// (the entry page, an actions sheet, a statement). The card is ``ShareCard``, which is also exactly
/// what is rendered to a PNG, so what a person approves and what lands in the thread are the same
/// picture. Colour is punctuation: the coral ground is the one place the app shouts.
struct ShareScreen: View {
    let artefact: ShareArtefact
    /// Where the share began — the entry page, an actions sheet, a statement. The north-star event's
    /// most interesting parameter.
    let source: ReceiptShareSource
    let analytics: AnalyticsRecorder

    @State private var photos: [AtePhoto] = []
    @State private var sender = ShareSender()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ShareStage(
            artefact: artefact,
            photos: photos,
            isPrinting: false,
            breathes: false,
            didFail: sender.didFail,
            onDone: { dismiss() },
            onShare: send
        )
        .task {
            photos = await SharePhotos.resolve(artefact.photoURLs)
            #if DEBUG
            dumpForDriveIfRequested()
            // `-ate-fail-share-render` taps Share for the drive too: the failure is a state of the
            // button, and a simulator cannot be tapped from a shell.
            if ShareSender.forcesRenderFailure { send() }
            #endif
        }
        .sheet(item: $sender.sending) { sending in
            ShareSheet(items: [sending.image])
        }
    }

    private func send() {
        sender.send(artefact: artefact, photos: photos) {
            analytics(EntryEvents.receiptShared(entryID: artefact.entryID, source: source))
        }
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
}

/// **The coral stage** a receipt stands on — `SummaryLoading` / `SummaryFinal`: the card tilted on
/// the ground with its two photos, `margin:180px 52px 0` from the top of the screen (`160` while it
/// is still printing, settling down to 180 as the lines arrive — the print's own motion), and the
/// two pills pinned `bottom:40px`, `left/right:20px`, `gap:10px`.
struct ShareStage: View {
    let artefact: ShareArtefact
    var photos: [AtePhoto]
    var isPrinting: Bool
    var breathes: Bool
    /// The last render produced nothing: the Share pill says what to do next, and nothing else does.
    var didFail = false
    let onDone: () -> Void
    let onShare: () -> Void

    var body: some View {
        ZStack(alignment: .top) {
            ShareCard(artefact: artefact, photos: photos, isPrinting: isPrinting, breathes: breathes)
                .padding(.horizontal, ShareCard.inset)
                .ateContentTop(isPrinting ? Self.printingTop : Self.cardTop)
                .ateAnimation(AteMotion.settle, value: isPrinting)
            VStack {
                Spacer(minLength: 0)
                actions
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .ateAccentGround(AteColor.coral)
    }

    /// `SummaryFinal`: Done `width:118px`, white; Share fills the rest, ink, with its icon. While the
    /// receipt prints, Share is there but off (`opacity:.35`) — there is nothing to send yet.
    private var actions: some View {
        HStack(spacing: Self.actionGap) {
            AteButton(title: "Done", isSecondary: true, action: onDone)
                .frame(width: Self.doneWidth)
                .accessibilityIdentifier("share.done")
            AteButton(icon: .share, title: didFail ? "Try again" : "Share", action: onShare)
                .disabled(isPrinting)
                .opacity(isPrinting ? Self.disabledOpacity : 1)
                .accessibilityIdentifier("share.send")
        }
        .padding(.horizontal, AteMetrics.gutter)
        .ateContentBottom(Self.actionsBottom)
    }

    /// `margin-top:180px` — and `160` while printing (`SummaryLoading`).
    static let cardTop: CGFloat = 180
    static let printingTop: CGFloat = 160
    /// `bottom:40px`.
    private static let actionsBottom: CGFloat = 40
    private static let actionGap: CGFloat = 10
    private static let doneWidth: CGFloat = 118
    private static let disabledOpacity: Double = 0.35
}

/// Render, and hand it to the system. **A render that fails is never silent**: it does not open the
/// sheet and does not count as a share; the pill says "Try again" — one word on the control itself,
/// no toast, no banner (design rule 1).
struct ShareSender {
    /// The rendered picture — `Identifiable` so it can present the system sheet.
    struct Sending: Identifiable {
        let id = UUID()
        let image: UIImage
    }

    var sending: Sending?
    var didFail = false

    @MainActor
    mutating func send(artefact: ShareArtefact, photos: [AtePhoto], onSent: () -> Void) {
        guard let image = Self.render(artefact: artefact, photos: photos) else {
            didFail = true
            return
        }
        didFail = false
        onSent()
        sending = Sending(image: image)
    }

    @MainActor
    private static func render(artefact: ShareArtefact, photos: [AtePhoto]) -> UIImage? {
        #if DEBUG
        if forcesRenderFailure { return nil }
        #endif
        return ShareImage.render(artefact: artefact, photos: photos)
    }

    #if DEBUG
    /// `-ate-fail-share-render`: the one state that cannot be reached by using the app, made
    /// reachable so it can be driven and looked at like every other.
    static var forcesRenderFailure: Bool {
        ProcessInfo.processInfo.arguments.contains("-ate-fail-share-render")
    }
    #endif
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
