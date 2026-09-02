import AteKit
import SwiftUI
import UIKit

// MARK: - Model

/// Where a card's photo lives. A staged photo (just picked, maybe still uploading) is a file on
/// disk; a posted one is a URL. Both are "the photo" as far as layout is concerned.
enum DishCardPhoto: Hashable {
    case local(URL)
    case remote(URL)
}

/// The byline. Present only in modes that show one — a compose card's author is obviously you.
struct DishCardAuthor: Hashable {
    let name: String
    let handle: String
    let avatarURL: URL?

    init(name: String, handle: String, avatarURL: URL? = nil) {
        self.name = name
        self.handle = handle
        self.avatarURL = avatarURL
    }
}

/// **Custom surface #2's data** (§3.1).
///
/// Deliberately *not* coupled to the log's `SittingDish`, a `FeedEntry`, or a review row: the same
/// card renders in five places, and if its model knew about any one of them, the other four would
/// have to fake it. Feed and Diary construct it from a ``FeedEntry``; the log constructs it from the
/// sitting; Detail from the loaded review.
struct DishCardModel: Identifiable, Hashable {
    let id: UUID
    /// Display string. Never an identifier — the card routes by ``dishID``.
    let dishName: String
    let dishID: UUID
    let restaurantName: String
    let restaurantSuburb: String?
    /// `nil` is the unrated state, rendered `–/5` (§3.3). Never zero.
    let score: Double?
    let reviewCount: Int?
    let note: String?
    let photo: DishCardPhoto?
    let author: DishCardAuthor?
    let timestamp: Date?

    init(
        id: UUID,
        dishName: String,
        dishID: UUID,
        restaurantName: String,
        restaurantSuburb: String? = nil,
        score: Double? = nil,
        reviewCount: Int? = nil,
        note: String? = nil,
        photo: DishCardPhoto? = nil,
        author: DishCardAuthor? = nil,
        timestamp: Date? = nil
    ) {
        self.id = id
        self.dishName = dishName
        self.dishID = dishID
        self.restaurantName = restaurantName
        self.restaurantSuburb = restaurantSuburb
        self.score = score
        self.reviewCount = reviewCount
        self.note = note
        self.photo = photo
        self.author = author
        self.timestamp = timestamp
    }

    /// The Feed/Diary construction. Lives here rather than in the Feed so there is exactly one
    /// mapping from a review row to a card, whichever screen is showing it.
    init(_ entry: FeedEntry) {
        self.init(
            id: entry.review.id,
            dishName: entry.dish.name,
            dishID: entry.dish.canonicalID,
            restaurantName: entry.restaurant.name,
            restaurantSuburb: entry.restaurant.locality,
            score: entry.review.score.value,
            note: entry.review.note,
            photo: entry.review.photoURL.map(DishCardPhoto.remote),
            author: entry.author.map {
                DishCardAuthor(name: $0.name, handle: $0.handle, avatarURL: $0.avatarURL)
            },
            timestamp: entry.review.createdAt
        )
    }
}

/// §3.1. Five modes, one card — the difference is which zones appear and whether the score zone is a
/// readout or the live gesture.
enum DishCardMode: Hashable {
    case compose
    case feed
    case diary
    case detail
    case receipt

    var showsAuthorStrip: Bool { self == .feed }
    var showsDateLabel: Bool { self == .diary }
    var isCompose: Bool { self == .compose }
    /// §3.2: the note is clamped in a feed (tap the card for the rest); everywhere else it's whole.
    var noteLineLimit: Int? { self == .feed ? 3 : nil }
    /// The receipt draws its own surface — a card-on-card would read as a screenshot of the app
    /// rather than as an artifact.
    var hasContainer: Bool { self != .receipt }
}

/// What a card can do. Everything defaults to nothing, so a read-mode card is `DishCard(model:mode:)`
/// and only the compose card wires the full set.
struct DishCardActions {
    var rating: Binding<Rating?> = .constant(nil)
    var note: Binding<String> = .constant("")
    var onRatingChanged: (Rating, LogRatingMethod) -> Void = { _, _ in }
    var onAddPhoto: (() -> Void)?
    var onRemovePhoto: (() -> Void)?
    var onRetryPhotoUpload: (() -> Void)?
    var onRemoveDish: (() -> Void)?
    var onClearRating: (() -> Void)?
    /// Upload progress for a staged photo (§3.5). `nil` = no photo, or a photo that isn't ours.
    var photoUploadState: PhotoUploadState?
    /// Bumped to run the §2.4 invalid-on-post wiggle on this card's rating.
    var wiggleTrigger: Int = 0
}

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

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.regular) {
            authorStrip
            identityBlock
            scoreZone
            photoZone
            noteZone
            affordanceRow
        }
        .padding(mode.hasContainer ? Theme.Spacing.comfortable : 0)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            if mode.hasContainer {
                RoundedRectangle(cornerRadius: Theme.Radius.card)
                    .fill(Theme.Color.surface)
            }
        }
        // §3.4: only the compose card owns a long press. Read modes get theirs from their host —
        // the feed's "open dish / open restaurant / share" belongs to the screen that can navigate.
        .modifier(ComposeContextMenu(isEnabled: hasContextMenu, content: contextMenuItems))
    }

    private var hasContextMenu: Bool {
        mode.isCompose && (actions.onRemoveDish != nil || actions.onClearRating != nil)
    }

    // MARK: Zones

    @ViewBuilder
    private var authorStrip: some View {
        if mode.showsAuthorStrip, let author = model.author {
            HStack(spacing: Theme.Spacing.snug) {
                AvatarView(url: author.avatarURL)
                Text(author.handle)
                    .font(Theme.Text.detail)
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

    private var identityBlock: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.tight) {
            Text(model.dishName)
                .font(Theme.Text.itemTitle)
                .foregroundStyle(foreground)
                .lineLimit(2)
                .truncationMode(.tail)
            Text(placeLine)
                .font(Theme.Text.detail)
                .foregroundStyle(secondaryForeground)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
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
            HStack(spacing: Theme.Spacing.comfortable) {
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
        VStack(spacing: Theme.Spacing.comfortable) {
            DishCard(model: .preview, mode: .feed)
            DishCard(model: .preview, mode: .diary)
            DishCard(model: .previewUnrated, mode: .detail)
        }
        .padding(Theme.Spacing.comfortable)
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
