import AteKit
import SwiftUI
import UIKit

/// **Share** — from the Printed screen and from your own entry, one sheet (10 Oct, approved): close
/// top left and Copy sticker top right; a swipeable carousel of the three stickers on their story
/// pages (``AteShareStory``) with the slip-on-photo first, so nobody has to swipe; and a fixed
/// "Share to" row at the foot — Instagram Stories · Copy link · Messages · Save image · More — where
/// Stories and the link are the same size and the same tap.
///
/// Instagram Stories is in the row only when the phone has Instagram and the Facebook App ID is
/// configured (``InstagramStories``). The photos are fetched before anything renders, so the page
/// that leaves is the page on screen. A share is counted when it actually leaves, by sticker and
/// by destination (`receipt_shared`).
struct V2ReceiptShareSheet: View {
    let receipt: AteReceipt
    /// The entry's photos, in order — fetched here, or already in hand (the composer's own).
    var photoURLs: [URL] = []
    var photos: [AtePhoto] = []
    /// The screen the share started on: the entry page, or the Summary after Done.
    var source: ReceiptShareSource = .entry
    let analytics: AnalyticsRecorder

    @State private var loaded: [AtePhoto] = []
    @State private var photosLoaded = false
    @State private var selected: ShareSticker? = .photo
    @State private var dishIndex = 0
    @State private var rendered: AteShareRender?
    @State private var sending: ShareSender.Sending?
    @State private var messaging: MessagesComposer.Draft?
    @State private var said: (id: String, word: String)?
    @State private var isSaving = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            AteSheetHeader(title: nil, primary: copySticker) { dismiss() }
            GeometryReader { room in
                carousel(in: room.size)
            }
            dots
            AteShareRow(actions: actions)
                .padding(.horizontal, AteMetrics.gutter)
                .padding(.top, AteMetrics.section)
                .padding(.bottom, AteSheetScaffoldMetrics.bareBottom)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .ateAccentGround(AteColor.coral)
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .task {
            if photos.isEmpty {
                loaded = await SharePhotos.resolve(photoURLs, limit: receipt.items.count)
            } else {
                loaded = photos
            }
            photosLoaded = true
            if loaded.isEmpty { selected = .slip }
        }
        .sheet(item: $sending) { sending in
            ShareSheet(sending: sending) { destination in count(destination) }
        }
        .sheet(item: $messaging) { draft in
            MessagesComposer(draft: draft) { sent in
                messaging = nil
                if sent { count(.messages) }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("share.sheet")
    }

    // MARK: - The stickers

    /// Which stickers this entry can make: the slip always; the photo pages only with a photo.
    private var stickers: [ShareSticker] {
        loaded.isEmpty ? [.slip] : [.photo, .slip, .dish]
    }

    private func carousel(in room: CGSize) -> some View {
        let height = room.height - AteMetrics.section * 2
        let width = height * AteShareStoryMetrics.width / AteShareStoryMetrics.height
        let scale = width / AteShareStoryMetrics.width
        let side = max(0, (room.width - width) / 2)
        return ScrollView(.horizontal) {
            LazyHStack(spacing: AteMetrics.regular) {
                ForEach(stickers, id: \.self) { sticker in
                    AteScaledLayout(scale: scale) {
                        story(sticker).scaleEffect(scale)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: AteShareStoryMetrics.radius, style: .continuous))
                    .ateBackground(.clear, in: RoundedRectangle(cornerRadius: AteShareStoryMetrics.radius,
                                                                style: .continuous), shadow: .cover)
                    .id(sticker)
                    .accessibilityIdentifier("share.sticker.\(sticker.rawValue)")
                }
            }
            .scrollTargetLayout()
            .padding(.vertical, AteMetrics.section)
        }
        .contentMargins(.horizontal, side, for: .scrollContent)
        .scrollTargetBehavior(.viewAligned)
        .scrollPosition(id: $selected)
        .scrollIndicators(.hidden)
        .scrollBounceBehavior(.basedOnSize)
    }

    /// The story page for a sticker, as the screen shows it (the first dish, on the dish page).
    private func story(_ sticker: ShareSticker, dish index: Int = 0) -> AteShareStory {
        let dish = receipt.items.indices.contains(index) ? receipt.items[index] : nil
        return AteShareStory(
            sticker: sticker, receipt: receipt,
            photo: sticker == .slip ? nil : photo(for: index), dish: dish
        )
    }

    /// The dish's own photo when the entry has one per dish, else the first.
    private func photo(for index: Int) -> AtePhoto? {
        loaded.indices.contains(index) ? loaded[index] : loaded.first
    }

    @ViewBuilder
    private var dots: some View {
        if stickers.count > 1 {
            HStack(spacing: AteMetrics.snug) {
                ForEach(stickers, id: \.self) { sticker in
                    Circle()
                        .fill(AteColor.ink.opacity(sticker == selected ? 1 : 0.3))
                        .frame(width: V2ShareMetrics.dot, height: V2ShareMetrics.dot)
                }
            }
            .accessibilityHidden(true)
        }
    }

    // MARK: - The ways out

    private var current: ShareSticker { selected ?? stickers.first ?? .slip }

    private var copySticker: AteSheetPrimary {
        AteSheetPrimary(
            icon: said?.id == "sticker" ? .check : .copy, label: "Copy sticker", isEnabled: photosLoaded
        ) { copyStickerToClipboard() }
    }

    private var actions: [AteShareRow.Action] {
        var row: [AteShareRow.Action] = []
        if InstagramStories.isAvailable {
            row.append(.init(id: "stories", icon: .camera, title: "Instagram Stories", isPrimary: true,
                             isEnabled: photosLoaded, action: shareToStories))
        }
        row.append(.init(id: "link", icon: .link, title: word("link", "Copy link"), isPrimary: row.isEmpty,
                         action: copyLink))
        row.append(.init(id: "messages", icon: .messageCircle, title: "Messages", isEnabled: photosLoaded,
                         action: message))
        row.append(.init(id: "save", icon: .download, title: word("save", "Save image"), isEnabled: photosLoaded,
                         isBusy: isSaving, action: save))
        row.append(.init(id: "more", icon: .more, title: "More", isEnabled: photosLoaded, action: more))
        return row
    }

    private func word(_ id: String, _ title: String) -> String {
        said?.id == id ? said?.word ?? title : title
    }

    /// The current sticker, rendered now — never ahead of time, so an edit between swipes is in it.
    private func render(dish index: Int = 0) -> AteShareRender? {
        guard let render = AteShareStoryImage.render(story(current, dish: index)) else {
            AteHaptics.refused()
            return nil
        }
        return render
    }

    private func shareToStories() {
        guard let render = render() else { return }
        guard InstagramStories.share(sticker: render.sticker, background: render.background) else {
            AteHaptics.refused()
            return
        }
        count(.instagramStories)
    }

    private func copyLink() {
        UIPasteboard.general.url = AteLinks.entry(receipt.id)
        say("link", "Copied")
        count(.link)
    }

    private func copyStickerToClipboard() {
        guard let render = render(), let png = render.sticker.pngData() else { return }
        UIPasteboard.general.setItems([["public.png": png]])
        say("sticker", "Copied")
        count(.clipboard)
    }

    private func message() {
        guard let render = render() else { return }
        let draft = MessagesComposer.Draft(body: AteLinks.entry(receipt.id).absoluteString, image: render.page)
        if MessagesComposer.canSend {
            messaging = draft
        } else {
            sending = ShareSender.Sending(image: render.page, sticker: render.sticker)
        }
    }

    /// The page to Photos — every dish's page, in order, on the dish sticker (the carousel wants one
    /// per slide).
    private func save() {
        let pages: [UIImage]
        if current == .dish {
            pages = receipt.items.indices.compactMap { render(dish: $0)?.page }
        } else {
            pages = [render()?.page].compactMap { $0 }
        }
        guard pages.isEmpty == false else { return }
        isSaving = true
        Task {
            let saved = await PhotoSaver.save(pages)
            isSaving = false
            if saved {
                say("save", pages.count > 1 ? "Saved \(pages.count)" : "Saved")
                count(.saved)
            } else {
                AteHaptics.refused()
            }
        }
    }

    private func more() {
        guard let render = render() else { return }
        sending = ShareSender.Sending(image: render.page, sticker: render.sticker)
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
            entryID: receipt.id, source: source, destination: destination, sticker: current
        ))
    }
}

enum V2ShareMetrics {
    static let dot: CGFloat = 6
    /// How long "Copied" stays on the control.
    static let wordHold: Duration = .seconds(1.5)
}
