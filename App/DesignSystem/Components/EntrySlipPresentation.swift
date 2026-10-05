import AteKit
import SwiftUI

/// **One row, three slips.** Turning an `entry_cards` row into the slip the design draws, in the one
/// place that does it — the journal, the feed and a profile show the same component and must never
/// drift into showing the same entry differently.
///
/// Pure and free of the network, so "what does this entry look like in a list" can be reasoned about
/// without one.
enum EntrySlipPresentation {

    /// Your own journal: no byline, no bookmarks (your entries are written, not saved), and the
    /// right of the foot line carries the day you ate.
    static func journal(_ card: EntryCard, timeZone: TimeZone = .autoupdatingCurrent) -> AteSlip {
        slip(card, surface: .journal, meta: .day(RelativeAge.day(card.createdAt, timeZone: timeZone)))
    }

    /// The feed: the person is named above the stack, every dish carries its own bookmark, and a
    /// visit of three dishes or more leaves its words to the entry (``SlipAnatomy``).
    static func feed(_ card: EntryCard, now: Date = Date()) -> AteSlip {
        var slip = slip(card, surface: .feed, meta: .none)
        slip.density = .tight
        // A blocked or deleted author is simply absent from the row (contract). The entry is still
        // readable; it just loses its byline rather than taking the page down.
        if let author = card.author {
            slip.byline = AteByline(
                userID: author.id,
                handle: author.username,
                age: RelativeAge.short(card.createdAt, now: now),
                with: CompanionLine.compact(card.companions.map(\.username))
            )
        }
        return slip
    }

    /// A profile: the byline would be the page's own title repeated, so the age moves to the right
    /// of the foot line — where the journal prints its date — and the stack keeps its bookmarks.
    static func profile(_ card: EntryCard, now: Date = Date()) -> AteSlip {
        slip(card, surface: .profile, meta: .age(RelativeAge.short(card.createdAt, now: now)))
    }

    /// **A visit on a place's own page** (`RestaurantVisits`, 2026-09-26): one stream, yours first.
    /// Every slip there carries the same byline row — yours reads "You" with the day you went, the
    /// rest their handle and age — and none carries the foot line: the page IS the place, so a pin
    /// would only name the room the reader is already in.
    static func placeVisit(
        _ card: EntryCard,
        now: Date = Date(),
        timeZone: TimeZone = .autoupdatingCurrent
    ) -> AteSlip {
        var slip = slip(card, surface: .feed, meta: .none)
        slip.place = nil
        slip.placeID = nil
        slip.suburb = nil
        if card.isMine {
            slip.byline = AteByline(
                userID: card.authorID,
                handle: card.author?.username ?? "",
                age: RelativeAge.day(card.createdAt, timeZone: timeZone),
                isYou: true
            )
        } else if let author = card.author {
            slip.byline = AteByline(
                userID: author.id,
                handle: author.username,
                age: RelativeAge.short(card.createdAt, now: now)
            )
        }
        return slip
    }

    // MARK: - The shape they share

    /// An entry's photos in the order they were added, each named by its address — the same photo
    /// is the same tile on every redraw, so a bookmark flipping never reloads a picture.
    static func viewerPhotos(_ card: EntryCard) -> [AtePhoto] {
        card.photos.sorted { $0.position < $1.position }.map { AtePhoto.remote($0.url) }
    }

    /// The design's cluster: three photos, tilted. A fourth would be a fourth angle and a wider
    /// stack than the artboard draws — the rest stay on the entry.
    private static let maximumPhotos = 3

    private static func slip(_ card: EntryCard, surface: SlipAnatomy.Surface, meta: AteSlip.Meta) -> AteSlip {
        // `MinimalEntry` (round 7): words that only name the dishes and their scores are said once,
        // in the rows — never again as prose under them.
        let showsWords = SlipAnatomy.showsWords(on: surface, dishCount: card.items.count)
            && EntryBodyTokens.wordsEchoDishRows(card) == false
        var slip = AteSlip(
            id: card.id,
            dishes: card.items.map {
                AteSlip.Dish(
                    id: $0.reviewID,
                    dishID: $0.dishID,
                    name: $0.dishName,
                    score: $0.score,
                    isSaved: $0.saved,
                    tags: $0.tags
                )
            },
            place: card.place?.name,
            placeID: card.place?.id,
            suburb: card.place?.suburb,
            meta: meta,
            // The words as written. A place named in them is plain text — the place is the foot
            // line's, never a pill in the prose (ComposerPlaceB).
            words: showsWords
                ? EntryPresentation.composition(for: card)
                : EntryComposition(plain: "", spans: []),
            photos: Array(viewerPhotos(card).prefix(maximumPhotos))
        )
        slip.viewerPhotos = viewerPhotos(card)
        slip.wordsLineLimit = SlipAnatomy.wordsLineLimit(on: surface)
        return slip
    }
}
