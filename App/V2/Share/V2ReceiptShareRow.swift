import AteKit
import SwiftUI
import UIKit

/// **The receipt's ways out** (11 Oct, approved: the ink share sheet): one scrolling row under the
/// cards, the apps in their own colours first — Stories, TikTok, Messages, Instagram — then Copy
/// link, Save image and More. Whatever card is showing is what leaves (``AteShareCard``), rendered at
/// the moment of the tap, so what leaves is what is on screen.
///
/// Instagram Stories takes each card its own way: the sticker as a sticker on Instagram's camera, the
/// story as its photo plus the receipt as a movable sticker, the post as the story's background.
/// Until the Facebook App ID is configured (or without Instagram on the phone) it hands the card to
/// the system sheet instead. TikTok and Instagram save the card to Photos and open the app
/// (``ShareApps``). A share is counted when it actually leaves, by card, look and destination
/// (`receipt_shared`); a disc that has just acted says so on itself — "Copied", "Saved" — and nothing
/// else does (design rule 1).
struct V2ReceiptShareRow: View {
    /// The card showing now, with its look.
    let card: AteShareCard
    /// The screen the share started on: the Printed screen after Done, or the entry page.
    let source: ReceiptShareSource
    /// Off while the receipt is still printing, or its photo is still on its way.
    var isEnabled = true
    let analytics: AnalyticsRecorder
    /// The first tap on any disc, once: the Printed screen's `summary_shared`.
    var onFirstShare: (() -> Void)?
    /// Whether one of the row's own sheets (the system sheet, Messages) is up.
    var isPresenting: Binding<Bool>?

    @State private var sending: ShareSender.Sending?
    @State private var messaging: MessagesComposer.Draft?
    @State private var said: (id: String, word: String)?
    @State private var busy: String?
    @State private var hasShared = false

    var body: some View {
        AteShareRow(actions: actions)
            .sheet(item: $sending, onDismiss: { isPresenting?.wrappedValue = false }, content: { sending in
                ShareSheet(sending: sending) { destination in count(destination) }
            })
            .sheet(item: $messaging, onDismiss: { isPresenting?.wrappedValue = false }, content: { draft in
                MessagesComposer(draft: draft) { sent in
                    messaging = nil
                    if sent { count(.messages) }
                }
            })
    }

    private var actions: [AteShareRow.Action] {
        [
            .init(id: "stories", icon: .instagram, title: "Stories", isEnabled: isEnabled, brand: .instagram,
                  action: shareToStories),
            .init(id: "tiktok", icon: .tiktok, title: word("tiktok", "TikTok"), isEnabled: isEnabled,
                  isBusy: busy == "tiktok", brand: .tiktok, action: shareToTikTok),
            .init(id: "messages", icon: .messageCircle, title: "Messages", isEnabled: isEnabled, brand: .messages,
                  action: message),
            .init(id: "instagram", icon: .instagram, title: "Instagram", isEnabled: isEnabled,
                  isBusy: busy == "instagram", brand: .instagram, action: shareToInstagram),
            .init(id: "link", icon: .link, title: word("link", "Copy link"), isEnabled: isEnabled, action: copyLink),
            .init(id: "save", icon: .download, title: word("save", "Save image"), isEnabled: isEnabled,
                  isBusy: busy == "save", action: save),
            .init(id: "more", icon: .more, title: "More", isEnabled: isEnabled, action: more)
        ]
    }

    private func word(_ id: String, _ title: String) -> String {
        said?.id == id ? said?.word ?? title : title
    }

    private var link: URL { AteLinks.entry(card.receipt.id) }

    /// The card, rendered now — never ahead of time, so what leaves is what is on screen.
    private func render() -> AteShareRender? {
        guard let render = AteShareCardImage.render(card) else {
            AteHaptics.refused()
            return nil
        }
        return render
    }

    private func shareToStories() {
        first()
        guard let render = render() else { return }
        guard InstagramStories.isAvailable else {
            present(ShareSender.Sending(image: render.page, sticker: render.sticker))
            return
        }
        let shared = switch card.format {
        case .sticker: InstagramStories.share(sticker: render.sticker)
        // The whole card, the receipt where it was put: Instagram would drop a sticker in the middle.
        case .story, .post: InstagramStories.share(sticker: nil, background: render.page)
        }
        if shared {
            count(.instagramStories)
        } else {
            AteHaptics.refused()
        }
    }

    /// Saved to Photos, then TikTok opened: its upload picker starts on the newest photo. Without
    /// TikTok on the phone the card is still saved, and the disc says so.
    private func shareToTikTok() {
        first()
        guard let page = render()?.page else { return }
        busy = "tiktok"
        Task {
            let saved = await PhotoSaver.save([page])
            busy = nil
            guard saved else {
                AteHaptics.refused()
                return
            }
            count(.tiktok)
            if await ShareApps.open(ShareApps.tiktok) == false { say("tiktok", "Saved") }
        }
    }

    /// Saved to Photos, then Instagram's composer opened on it; the system sheet when Instagram is
    /// not there to open.
    private func shareToInstagram() {
        first()
        guard let render = render() else { return }
        busy = "instagram"
        Task {
            let identifiers = await PhotoSaver.saveReturningIdentifiers([render.page])
            busy = nil
            if let identifier = identifiers?.first,
               await ShareApps.open(ShareApps.instagram(libraryIdentifier: identifier)) {
                count(.instagram)
            } else {
                present(ShareSender.Sending(image: render.page, sticker: render.sticker))
            }
        }
    }

    private func copyLink() {
        first()
        UIPasteboard.general.url = link
        say("link", "Copied")
        count(.link)
    }

    private func message() {
        first()
        guard let render = render() else { return }
        if MessagesComposer.canSend {
            isPresenting?.wrappedValue = true
            messaging = MessagesComposer.Draft(body: link.absoluteString, image: render.page)
        } else {
            present(ShareSender.Sending(image: render.page, sticker: render.sticker))
        }
    }

    private func save() {
        first()
        guard let page = render()?.page else { return }
        busy = "save"
        Task {
            let saved = await PhotoSaver.save([page])
            busy = nil
            if saved {
                say("save", "Saved")
                count(.saved)
            } else {
                AteHaptics.refused()
            }
        }
    }

    private func more() {
        first()
        guard let render = render() else { return }
        present(ShareSender.Sending(image: render.page, sticker: render.sticker))
    }

    private func present(_ sending: ShareSender.Sending) {
        isPresenting?.wrappedValue = true
        self.sending = sending
    }

    private func first() {
        guard hasShared == false else { return }
        hasShared = true
        onFirstShare?()
    }

    /// One word on the control itself, for a moment.
    private func say(_ id: String, _ word: String) {
        AteHaptics.key()
        said = (id, word)
        Task {
            try? await Task.sleep(for: V2ShareMetrics.wordHold)
            if said?.id == id { said = nil }
        }
    }

    private func count(_ destination: ShareDestination) {
        analytics(ShareEvents.receiptShared(
            entryID: card.receipt.id, source: source, destination: destination, sticker: card.format.counted,
            look: card.look.name(for: card.format), adjusted: card.look.isAdjusted(card.format),
            receiptMoved: card.look.isReceiptMoved(card.format)
        ))
    }
}

enum V2ShareMetrics {
    /// How long "Copied" stays on the control.
    static let wordHold: Duration = .seconds(1.5)
}
