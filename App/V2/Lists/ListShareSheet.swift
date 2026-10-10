import AteKit
import SwiftUI
import UIKit

/// What a list shares: enough to name it in a link's preview and on a story.
struct ListShare: Equatable {
    let id: UUID
    let name: String
    let count: Int
    /// The cover's photos, in list order (four at most).
    var covers: [String] = []
    let handle: String

    var countLine: String { count == 1 ? "1 dish" : "\(count) dishes" }
}

/// **Share: a list** (10 Oct, approved) — a link, the way a playlist is, never a picture of its
/// lines. The cover on the coral ground, the name and the count under it, and the row: Copy link
/// first, Messages, Instagram Stories (the cover as a sticker, as Spotify shares a playlist cover),
/// More. The link opens the list in Ate (``AteLinks/list(_:)``); its preview carries the name.
struct ListShareSheet: View {
    let share: ListShare
    let analytics: AnalyticsRecorder

    @State private var photos: [AtePhoto] = []
    @State private var photosLoaded = false
    @State private var sending: ShareSender.Sending?
    @State private var messaging: MessagesComposer.Draft?
    @State private var said: (id: String, word: String)?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            AteSheetHeader(title: nil) { dismiss() }
            GeometryReader { room in
                ScrollView {
                    preview
                        .padding(.vertical, AteMetrics.section)
                        .frame(maxWidth: .infinity, minHeight: room.size.height)
                }
                .scrollBounceBehavior(.basedOnSize)
                .scrollIndicators(.hidden)
            }
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
            photos = await SharePhotos.resolve(share.covers.compactMap(URL.init(string:)), limit: UserList.coverLimit)
            photosLoaded = true
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
        .accessibilityIdentifier("list.share.sheet")
    }

    /// The cover as the list page shows it, the name and the count under it.
    private var preview: some View {
        VStack(spacing: AteMetrics.regular) {
            AteListCover(id: share.id, name: share.name, covers: share.covers, style: .hero)
            Text(share.name)
                .ateText(.kitListHeroName)
                .foregroundStyle(AteColor.ink)
                .multilineTextAlignment(.center)
                .lineLimit(3)
            Text(verbatim: "\(share.countLine) · @\(share.handle)")
                .ateText(.kitListByline)
                .foregroundStyle(AteColor.ink.opacity(V2ListShareMetrics.bylineOpacity))
        }
        .padding(.horizontal, AteMetrics.gutter)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("list.share.preview")
    }

    private var link: URL { AteLinks.list(share.id) }

    private var actions: [AteShareRow.Action] {
        var row: [AteShareRow.Action] = [
            .init(id: "link", icon: .link, title: said?.id == "link" ? "Copied" : "Copy link", isPrimary: true,
                  action: copyLink),
            .init(id: "messages", icon: .messageCircle, title: "Messages", action: message)
        ]
        if InstagramStories.isAvailable {
            row.append(.init(id: "stories", icon: .camera, title: "Instagram Stories", isEnabled: photosLoaded,
                             action: shareToStories))
        }
        row.append(.init(id: "more", icon: .more, title: "More", action: more))
        return row
    }

    private func copyLink() {
        UIPasteboard.general.url = link
        AteHaptics.key()
        said = ("link", "Copied")
        count(.link)
        Task {
            try? await Task.sleep(for: V2ShareMetrics.wordHold)
            if said?.id == "link" { said = nil }
        }
    }

    private func message() {
        let draft = MessagesComposer.Draft(body: link.absoluteString, image: nil)
        if MessagesComposer.canSend {
            messaging = draft
        } else {
            more()
        }
    }

    /// The cover card as a sticker on the coral ground.
    private func shareToStories() {
        guard let sticker = AteListStoryImage.sticker(share, photos: photos) else {
            AteHaptics.refused()
            return
        }
        guard InstagramStories.share(sticker: sticker) else {
            AteHaptics.refused()
            return
        }
        count(.instagramStories)
    }

    /// The system sheet, handed the link dressed with the list's name.
    private func more() {
        let item = EntryLinkItem(url: link, title: "\(share.name) · \(share.countLine)")
        sending = ShareSender.Sending(image: UIImage(), sticker: nil, items: [item])
    }

    private func count(_ destination: ShareDestination) {
        analytics(ShareEvents.listShared(listID: share.id, destination: destination, count: share.count))
    }
}

enum V2ListShareMetrics {
    static let bylineOpacity: Double = 0.7
}

/// **The list's story card** — the cover with the name and the count on a paper card, for Instagram
/// Stories; the same photos already fetched for the sheet, so the renderer sees pictures rather than
/// placeholders.
struct AteListStoryCard: View {
    let share: ListShare
    var photos: [AtePhoto] = []

    var body: some View {
        VStack(alignment: .leading, spacing: AteMetrics.regular) {
            mosaic
                .frame(width: AteListStoryMetrics.cover, height: AteListStoryMetrics.cover)
                .clipShape(RoundedRectangle(cornerRadius: AteListCoverMetrics.radius, style: .continuous))
            Text(share.name)
                .ateText(.kitListReceiptTitle)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Text(verbatim: "\(share.countLine) · @\(share.handle)")
                    .ateText(.shareSlipLabel)
                    .lineLimit(1)
                Spacer(minLength: AteMetrics.snug)
                AteWordmark(height: AteShareSlipMetrics.wordmark)
            }
        }
        .padding(AteListStoryMetrics.inset)
        .frame(width: AteListStoryMetrics.width)
        .ateSlip()
        .background(RoundedRectangle(cornerRadius: AteListStoryMetrics.radius, style: .continuous)
            .fill(AtePalette.slip.ground))
    }

    @ViewBuilder
    private var mosaic: some View {
        if photos.count >= UserList.coverLimit {
            VStack(spacing: 0) {
                HStack(spacing: 0) { quarter(photos[0]); quarter(photos[1]) }
                HStack(spacing: 0) { quarter(photos[2]); quarter(photos[3]) }
            }
        } else if let first = photos.first {
            AtePhotoContent(photo: first, contentMode: .fill)
        } else {
            AteColor.coral
        }
    }

    private func quarter(_ photo: AtePhoto) -> some View {
        AtePhotoContent(photo: photo, contentMode: .fill)
            .frame(width: AteListStoryMetrics.cover / 2, height: AteListStoryMetrics.cover / 2)
            .clipped()
    }
}

enum AteListStoryMetrics {
    static let width: CGFloat = 232
    static let cover: CGFloat = 200
    static let inset: CGFloat = 16
    static let radius: CGFloat = 14
}

@MainActor
enum AteListStoryImage {
    static func sticker(_ share: ListShare, photos: [AtePhoto]) -> UIImage? {
        let content = AteListStoryCard(share: share, photos: photos)
            .foregroundStyle(AteColor.ink)
            .environment(\.dynamicTypeSize, .large)
            .environment(\.colorScheme, .light)
            .environment(\.ateIsSnapshotting, true)
        let renderer = ImageRenderer(content: content)
        renderer.scale = AteMetrics.shareExportScale
        renderer.isOpaque = false
        return renderer.uiImage
    }
}
