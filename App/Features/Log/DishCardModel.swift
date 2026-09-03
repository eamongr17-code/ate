import AteKit
import SwiftUI

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
    /// Rule R (§5): with an id in hand the place line becomes a link. `nil` where the card is
    /// composed rather than read (the sitting canvas already knows where you are) — the line then
    /// renders as plain text, never as a dead affordance.
    let restaurantID: UUID?
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
        restaurantID: UUID? = nil,
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
        self.restaurantID = restaurantID
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
            restaurantID: entry.restaurant.id,
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
    /// Your journal entry — the one card on its page. (Was `.diary`; renamed because the diary
    /// *list* is compact rows, and a mode named after a screen it doesn't appear on is a trap.)
    case entry
    case detail
    case receipt

    var showsAuthorStrip: Bool { self == .feed }
    /// Nothing, now. §2 makes the date the entry screen's *subtitle* — it is what the page IS, not a
    /// field of the review — and the card was printing it a second time three lines below.
    var showsDateLabel: Bool { false }
    var isCompose: Bool { self == .compose }
    /// §3.2: the note is clamped in a feed (tap the card for the rest); everywhere else it's whole.
    var noteLineLimit: Int? { self == .feed ? 3 : nil }

    /// **A card is never in a list of cards** (design-language §1.1). A container means "THIS is the
    /// subject of this page", so exactly two modes draw one: the entry view's single review, and a
    /// compose card on the log canvas. The feed is a *stream of peers* and sits on the plane, parted
    /// by hairlines; detail's card sits inside a Group; the receipt is its own artifact.
    var hasContainer: Bool { self == .entry || self == .compose }

    /// Rule R (§5): the read modes that sit inside a navigable list. The feed is the only one left —
    /// the entry view carries an explicit restaurant disclosure row, and a second, quieter path to
    /// the same place on the same screen is a duplicate affordance, not a convenience. The compose
    /// card's place line is the restaurant you are *currently at* and must not navigate away
    /// mid-sitting; receipt and detail carry the place elsewhere on their screens.
    var linksToRestaurant: Bool { self == .feed }

    /// Which Rule R site this card's place line is, for `restaurant_name_tapped`.
    var restaurantLinkOrigin: RestaurantLinkOrigin { self == .feed ? .feedRow : .diaryEntry }
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
