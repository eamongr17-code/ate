import AteKit
import SwiftUI
import UIKit

/// **The receipt's ways out** (10 Oct, approved): the row under a printed receipt, on the Printed
/// screen and on the entry page's share sheet alike — Instagram Stories first, in ink, then Copy
/// link, Messages, Save image, More. Nothing opens before a person can share: the receipt on
/// screen is the thing that leaves, as a story page (``AteShareStory``) with the entry's first
/// photo behind it when there is one.
///
/// Instagram Stories is always in the row. Until the Facebook App ID is configured (or without
/// Instagram on the phone) it hands the page to the system sheet instead, where Instagram's own
/// share extension sits. A share is counted when it actually leaves, by sticker and destination
/// (`receipt_shared`); a disc that has just acted says so on itself — "Copied", "Saved" — and
/// nothing else does (design rule 1).
struct V2ReceiptShareRow: View {
    let receipt: AteReceipt
    /// The entry's photos, already in hand. The first goes behind the receipt.
    var photos: [AtePhoto] = []
    /// The screen the share started on: the Printed screen after Done, or the entry page.
    let source: ReceiptShareSource
    /// Off while the receipt is still printing, or its photos are still on their way.
    var isEnabled = true
    let analytics: AnalyticsRecorder
    /// The first tap on any disc, once: the Printed screen's `summary_shared`.
    var onFirstShare: (() -> Void)?
    /// Whether one of the row's own sheets (the system sheet, Messages) is up.
    var isPresenting: Binding<Bool>?

    @State private var sending: ShareSender.Sending?
    @State private var messaging: MessagesComposer.Draft?
    @State private var said: (id: String, word: String)?
    @State private var isSaving = false
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
            .init(id: "stories", icon: .camera, title: "Instagram Stories", isPrimary: true, isEnabled: isEnabled,
                  action: shareToStories),
            .init(id: "link", icon: .link, title: word("link", "Copy link"), isEnabled: isEnabled, action: copyLink),
            .init(id: "messages", icon: .messageCircle, title: "Messages", isEnabled: isEnabled, action: message),
            .init(id: "save", icon: .download, title: word("save", "Save image"), isEnabled: isEnabled,
                  isBusy: isSaving, action: save),
            .init(id: "more", icon: .more, title: "More", isEnabled: isEnabled, action: more)
        ]
    }

    private func word(_ id: String, _ title: String) -> String {
        said?.id == id ? said?.word ?? title : title
    }

    private var story: AteShareStory {
        AteShareStory(receipt: receipt, photo: photos.first)
    }

    private var link: URL { AteLinks.entry(receipt.id) }

    /// The page, rendered now — never ahead of time, so what leaves is what is on screen.
    private func render() -> AteShareRender? {
        guard let render = AteShareStoryImage.render(story) else {
            AteHaptics.refused()
            return nil
        }
        return render
    }

    private func shareToStories() {
        first()
        guard let render = render() else { return }
        if InstagramStories.isAvailable {
            guard InstagramStories.share(sticker: render.sticker, background: render.background) else {
                AteHaptics.refused()
                return
            }
            count(.instagramStories)
        } else {
            present(ShareSender.Sending(image: render.page, sticker: render.sticker))
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
        isSaving = true
        Task {
            let saved = await PhotoSaver.save([page])
            isSaving = false
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
            entryID: receipt.id, source: source, destination: destination, sticker: story.sticker
        ))
    }
}

enum V2ShareMetrics {
    /// How long "Copied" stays on the control.
    static let wordHold: Duration = .seconds(1.5)
}
