import AteKit
import SwiftUI
import UIKit

// MARK: - View

/// **Custom surface #2** — the dish unit (§3).
///
/// One structural rule outranks every other: **dish name above restaurant name, always, in every
/// mode.** The dish is the atom of this product (PRODUCT.md); a card that leads with the venue is a
/// restaurant-review app, which is the thing Ate is not.
struct DishCard: View {
    let model: DishCardModel
    var mode: DishCardMode = .feed
    var actions = DishCardActions()

    /// §1.3: the note costs zero taps on the happy path — it's an icon until you want it.
    @State private var isNoteExpanded = false
    @FocusState private var isNoteFocused: Bool

    /// §9's question #2. Only the feed reads it; every other mode has one layout.
    @AppStorage(DesignDebugSettings.feedRowLayoutKey)
    private var feedRowLayoutRaw = FeedRowLayout.designDefault.rawValue

    private var feedRowLayout: FeedRowLayout {
        #if DEBUG || BETA
        FeedRowLayout(rawValue: feedRowLayoutRaw) ?? .designDefault
        #else
        .designDefault
        #endif
    }

    var body: some View {
        layout
            .padding(mode.hasContainer ? Theme.Spacing.gutter : 0)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                if mode.hasContainer {
                    RoundedRectangle(cornerRadius: Theme.Radius.card)
                        .fill(Theme.Color.surfaceCard)
                }
            }
            // §3.4: only the compose card owns a long press. Read modes get theirs from their host —
            // the feed's "open dish / open restaurant / share" belongs to the screen that can navigate.
            .modifier(ComposeContextMenu(isEnabled: hasContextMenu, content: contextMenuItems))
    }

    private var hasContextMenu: Bool {
        mode.isCompose && (actions.onRemoveDish != nil || actions.onClearRating != nil)
    }

    // MARK: Layout

    /// One stack of zones everywhere — except on the feed, which is the app's density question (§9).
    @ViewBuilder
    private var layout: some View {
        if mode == .feed, feedRowLayout == .photoLeading {
            photoLeadingLayout
        } else {
            stackedLayout
        }
    }

    private var stackedLayout: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.regular) {
            authorStrip
            identityBlock
            scoreZone
            photoZone
            noteZone
            affordanceRow
        }
    }

    /// **Variant B.** The photo becomes a 72pt leading tile and the text runs beside it, fitting
    /// roughly twice as many reviews on a screen. The tile is a *gutter* here, not decoration, so it
    /// is always filled: a row that sometimes has a left column and sometimes doesn't is a ragged
    /// list, which is the thing the tile exists to prevent.
    private var photoLeadingLayout: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.regular) {
            DishTile(dish: tileSubject, size: Theme.Size.tileFeedLeading)
            VStack(alignment: .leading, spacing: Theme.Spacing.snug) {
                authorStrip
                identityBlock
                scoreZone
                noteZone
            }
        }
    }

    /// The dish behind the tile. Routes and tiles both key off the canonical dish id; the remote
    /// photo is the only kind a read-mode card can have.
    private var tileSubject: DishTileSubject {
        DishTileSubject(
            id: model.dishID,
            name: model.dishName,
            photoURL: {
                if case .remote(let url) = model.photo { return url }
                return nil
            }()
        )
    }

    // MARK: Zones

    @ViewBuilder
    private var authorStrip: some View {
        if mode.showsAuthorStrip, let author = model.author {
            HStack(spacing: Theme.Spacing.snug) {
                AvatarView(url: author.avatarURL)
                Text(author.handle)
                    .font(Theme.Text.streamByline)
                    .foregroundStyle(Theme.Color.textSecondary)
                Spacer(minLength: Theme.Spacing.snug)
                if let timestamp = model.timestamp {
                    Text(timestamp, format: .relative(presentation: .numeric))
                        .font(Theme.Text.caption)
                        .foregroundStyle(Theme.Color.textTertiary)
                }
            }
        } else if mode.showsDateLabel, let timestamp = model.timestamp {
            Text(timestamp, format: .dateTime.day().month(.abbreviated).year())
                .font(Theme.Text.caption)
                .foregroundStyle(Theme.Color.textSecondary)
        }
    }

    /// Dish name over place line.
    ///
    /// The accessibility treatment follows the *affordance*, not the layout: where the place line is
    /// a Rule R link (feed only), the block must stay two elements or VoiceOver swallows the link
    /// and leaves the restaurant unreachable. Where it is plain text — every other mode — combining
    /// is strictly better: "Prawn betel leaf, Chin Chin · Melbourne" is one thought, and two swipes
    /// to hear it is two swipes too many.
    private var identityBlock: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.tight) {
            Text(model.dishName)
                .font(Theme.Text.itemTitle)
                .foregroundStyle(foreground)
                .lineLimit(2)
                .truncationMode(.tail)
            placeLineView
        }
        .modifier(CombineWhenNotLinked(isLinked: mode.linksToRestaurant && model.restaurantID != nil))
    }

    /// Rule R (§5). Deliberately NOT inside the identity block's combined accessibility element —
    /// a combined element would swallow the link and leave the restaurant unreachable by VoiceOver,
    /// which is the exact failure Rule R exists to prevent.
    @ViewBuilder
    private var placeLineView: some View {
        if mode.linksToRestaurant, let restaurantID = model.restaurantID {
            RestaurantNameLink(
                name: model.restaurantName,
                suburb: model.restaurantSuburb,
                restaurantID: restaurantID,
                from: mode.restaurantLinkOrigin,
                style: .inline,
                font: Theme.Text.detail,
                foreground: secondaryForeground
            )
        } else {
            Text(placeLine)
                .font(Theme.Text.detail)
                .foregroundStyle(secondaryForeground)
                .lineLimit(1)
        }
    }

    @ViewBuilder
    private var scoreZone: some View {
        if mode.isCompose {
            RatingControl(
                rating: actions.rating,
                onChange: actions.onRatingChanged,
                wiggleTrigger: actions.wiggleTrigger
            )
        } else {
            // §3.3: the review count rides along in detail/menu contexts only.
            ScoreMark(score: model.score, reviewCount: mode == .detail ? model.reviewCount : nil)
        }
    }

    @ViewBuilder
    private var photoZone: some View {
        if let photo = model.photo {
            DishCardPhotoView(
                photo: photo,
                uploadState: actions.photoUploadState,
                onRetry: actions.onRetryPhotoUpload,
                onRemove: mode.isCompose ? actions.onRemovePhoto : nil
            )
        }
    }

    @ViewBuilder
    private var noteZone: some View {
        if mode.isCompose {
            if isNoteShowing {
                TextField("Add a note", text: actions.note, axis: .vertical)
                    .font(Theme.Text.body)
                    .lineLimit(1...4)
                    .focused($isNoteFocused)
                    .textInputAutocapitalization(.sentences)
            }
        } else if let note = model.note, !note.isEmpty {
            Text(note)
                .font(Theme.Text.body)
                .foregroundStyle(foreground)
                .lineLimit(mode.noteLineLimit)
        }
    }

    /// §3.2 zone 6: two borderless icon buttons, visually subordinate to the rating. No labels — a
    /// labelled "Add a note" button competes with the thing that matters.
    ///
    /// Both are **toggles**, not one-way doors (device feedback): an icon that opened something and
    /// then does nothing on the second tap reads as broken, and leaves no way back from a note field
    /// or a photo you didn't want. Off is the same tap that turned it on, and each is tinted while
    /// it is on, so what the next tap will do is legible before you make it.
    @ViewBuilder
    private var affordanceRow: some View {
        if mode.isCompose {
            HStack(spacing: Theme.Spacing.gutter) {
                Spacer(minLength: 0)
                Button(action: toggleNote) {
                    Image(systemName: "note.text")
                        .foregroundStyle(isNoteShowing ? Theme.Color.accent : Theme.Color.textSecondary)
                }
                .accessibilityLabel(isNoteShowing ? "Remove the note" : "Add a note")

                photoButton
            }
            .buttonStyle(.plain)
            .font(Theme.Text.detail)
            .foregroundStyle(Theme.Color.textSecondary)
        }
    }

    @ViewBuilder
    private var photoButton: some View {
        if model.photo != nil, let onRemovePhoto = actions.onRemovePhoto {
            // The second path to the photo's own ✕ — the icon that added it takes it away.
            Button(action: onRemovePhoto) {
                Image(systemName: "camera.fill")
                    .foregroundStyle(Theme.Color.accent)
            }
            .accessibilityLabel("Remove the photo")
        } else if let onAddPhoto = actions.onAddPhoto {
            Button(action: onAddPhoto) {
                Image(systemName: "camera")
            }
            .accessibilityLabel("Add a photo")
        }
    }

    /// The note field is on screen either because the icon opened it or because there is text in it,
    /// so "is it showing?" has one answer and the toggle can't disagree with the zone.
    private var isNoteShowing: Bool {
        isNoteExpanded || !actions.note.wrappedValue.isEmpty
    }

    private func toggleNote() {
        guard isNoteShowing else {
            isNoteExpanded = true
            isNoteFocused = true
            return
        }
        // Collapsing has to clear the text as well, or the zone would refuse to close — and the
        // cleared note has to reach the draft, which it does: the binding is the sitting's note.
        isNoteFocused = false
        isNoteExpanded = false
        if !actions.note.wrappedValue.isEmpty {
            actions.note.wrappedValue = ""
        }
    }

    @ViewBuilder
    private var contextMenuItems: some View {
        if let onClearRating = actions.onClearRating, actions.rating.wrappedValue != nil {
            Button("Clear rating", systemImage: "arrow.uturn.backward", action: onClearRating)
        }
        if let onRemoveDish = actions.onRemoveDish {
            Button("Remove dish", systemImage: "trash", role: .destructive, action: onRemoveDish)
        }
    }

    // MARK: Bits

    private var placeLine: String {
        guard let suburb = model.restaurantSuburb, !suburb.isEmpty else { return model.restaurantName }
        return "\(model.restaurantName) · \(suburb)"
    }

    private var foreground: Color {
        mode == .receipt ? Theme.Color.receiptForeground : Theme.Color.textPrimary
    }

    private var secondaryForeground: Color {
        mode == .receipt ? Theme.Color.receiptSecondary : Theme.Color.textSecondary
    }
}

/// Combines the identity block into one VoiceOver element *unless* it contains a link. Applied as a
/// modifier rather than a `.accessibilityElement(children:)` with a computed argument because
/// `.contain` is not the same as leaving the element alone — the link needs no wrapper at all.
private struct CombineWhenNotLinked: ViewModifier {
    let isLinked: Bool

    func body(content: Content) -> some View {
        if isLinked {
            content
        } else {
            content.accessibilityElement(children: .combine)
        }
    }
}

/// Attaches a context menu only when there is something in it. An empty `.contextMenu` still arms a
/// long press, which reads as a broken gesture.
private struct ComposeContextMenu<MenuContent: View>: ViewModifier {
    let isEnabled: Bool
    let content: MenuContent

    func body(content base: Content) -> some View {
        if isEnabled {
            base.contextMenu { self.content }
        } else {
            base
        }
    }
}

// MARK: - Previews

#Preview("Modes") {
    ScrollView {
        VStack(spacing: Theme.Spacing.gutter) {
            DishCard(model: .preview, mode: .feed)
            DishCard(model: .preview, mode: .entry)
            DishCard(model: .previewUnrated, mode: .detail)
        }
        .padding(Theme.Spacing.gutter)
    }
    .background(Theme.Color.background)
}

extension DishCardModel {
    static var preview: DishCardModel {
        DishCardModel(
            id: UUID(),
            dishName: "Prawn betel leaf",
            dishID: UUID(),
            restaurantName: "Chin Chin",
            restaurantSuburb: "Melbourne",
            score: 4.5,
            reviewCount: 12,
            note: "The one thing you have to order. Sweet, sour, crunchy, gone in one bite.",
            author: DishCardAuthor(name: "Eamon", handle: "@eamon"),
            timestamp: Date().addingTimeInterval(-3_600)
        )
    }

    static var previewUnrated: DishCardModel {
        DishCardModel(
            id: UUID(),
            dishName: "Son-in-law eggs",
            dishID: UUID(),
            restaurantName: "Chin Chin",
            restaurantSuburb: "Melbourne",
            score: nil,
            reviewCount: 0
        )
    }
}
