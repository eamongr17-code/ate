import AteKit
import SwiftUI
import UIKit

// The two sub-views of ``DishCard`` big enough to own a file: the photo well and the byline avatar.
// Split out of `DishCard.swift` when it outgrew the file-length budget; no behaviour moved with them.

/// The photo zone (§3.2 zone 4, §3.5). Never a grey placeholder when there's no photo — the zone is
/// simply absent and the card is shorter.
struct DishCardPhotoView: View {
    let photo: DishCardPhoto
    var uploadState: PhotoUploadState?
    var onRetry: (() -> Void)?
    var onRemove: (() -> Void)?

    /// The decoded staged photo, held across body passes.
    ///
    /// Decoding in `body` (which is what an inline `UIImage(contentsOfFile:)` did) re-read and
    /// re-decoded a 2048 px JPEG off disk on *every* invalidation — and the compose card is
    /// invalidated on every half-step of a scrub, because the score lives in the same `@Observable`
    /// sitting the card is built from. On a real device that is the difference between a 1:1 fill
    /// and a stuttering one; the simulator hides it behind a desktop CPU.
    @State private var stagedImage: UIImage?

    /// A 4:3 well that takes the card's width, with the photo filling it.
    ///
    /// The **well** is what sizes the zone: an image sized by its own aspect ratio pushes its
    /// intrinsic (pixel) width into the layout and shoves the whole row sideways — the bug `FeedRow`
    /// documents, and the one a remote photo in the Diary list reproduced. `Color.clear` sets the
    /// geometry; the image is an overlay clipped to it, so a portrait, panoramic or 4000px-wide
    /// photo can never change the card's shape.
    var body: some View {
        Color.clear
            .aspectRatio(Theme.Ratio.photo, contentMode: .fit)
            .overlay { image }
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card))
            .opacity(uploadState?.isInFlight == true ? 0.6 : 1)
            .overlay(alignment: .center) { uploadOverlay }
            .overlay(alignment: .topTrailing) { removeButton }
            .accessibilityLabel("Dish photo")
            .task(id: photo) { await loadStagedImage() }
    }

    /// Off the main actor, once per file, and re-run only when the photo itself changes.
    private func loadStagedImage() async {
        guard case .local(let url) = photo else {
            stagedImage = nil
            return
        }
        let path = url.path(percentEncoded: false)
        stagedImage = await Task.detached(priority: .userInitiated) {
            UIImage(contentsOfFile: path)
        }.value
    }

    @ViewBuilder
    private var image: some View {
        switch photo {
        case .local:
            if let stagedImage {
                Image(uiImage: stagedImage).resizable().scaledToFill()
            } else {
                Theme.Color.placeholder
            }
        case .remote(let url):
            AsyncImage(url: url) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                Theme.Color.placeholder
            }
        }
    }

    @ViewBuilder
    private var uploadOverlay: some View {
        switch uploadState {
        case .uploading:
            ProgressView()
                .controlSize(.large)
        case .failed:
            // §3.5: a failed upload is a retry affordance, never a blocker — the post goes without it.
            Button {
                onRetry?()
            } label: {
                Image(systemName: "exclamationmark.arrow.circlepath")
                    .font(Theme.Text.sectionTitle)
                    .padding(Theme.Spacing.regular)
                    .background(.thinMaterial, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Photo upload failed. Retry")
        case .uploaded, .none:
            EmptyView()
        }
    }

    @ViewBuilder
    private var removeButton: some View {
        if let onRemove {
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .font(Theme.Text.sectionTitle)
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(Theme.Color.background, Theme.Color.textSecondary)
                    .padding(Theme.Spacing.snug)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove photo")
        }
    }
}

/// A byline avatar, or its initial-less fallback. Never a broken-image glyph.
struct AvatarView: View {
    let url: URL?
    var size: CGFloat = Theme.Size.avatarByline

    var body: some View {
        AsyncImage(url: url) { image in
            image.resizable().scaledToFill()
        } placeholder: {
            Theme.Color.placeholder
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .accessibilityHidden(true)
    }
}
