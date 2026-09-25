import AteKit
import SwiftUI

/// What a slip shows: an entry, reduced to the parts that survive being one of many in a list.
///
/// **One card anatomy** for the journal, the feed and a profile (`docs/DESIGN.md`): the feed's
/// byline on top, then the dish rows, the words, the tilted photos, and a foot line of pin + place +
/// suburb — with the journal's date, or a profile's age, at its right. The dish is the item: the
/// place is a pin line at the foot.
struct AteSlip: Equatable, Identifiable {
    /// One line of the stack: a dish, a score, and whether the viewer has it saved.
    struct Dish: Equatable, Identifiable {
        /// The review line's id — unique within an entry even when a dish repeats.
        let id: UUID
        var dishID: UUID
        var name: String
        var score: Rating?
        var isSaved: Bool

        init(id: UUID, dishID: UUID, name: String, score: Rating? = nil, isSaved: Bool = false) {
            self.id = id
            self.dishID = dishID
            self.name = name
            self.score = score
            self.isSaved = isSaved
        }
    }

    /// What the right-hand end of the foot line says. Design rule 2: two values, left and right,
    /// never a dot separator.
    enum Meta: Equatable {
        /// Your own journal: the day you ate — "Sat 19 Sep". A date, never a time.
        case day(String)
        /// A profile: how long ago. (In the feed the byline already carries it.)
        case age(String)
        case none
    }

    let id: UUID
    var dishes: [Dish]
    /// `nil` when no place is attached — it is drawn as nothing, never as a guess (design rule 8).
    var place: String?
    var placeID: UUID?
    /// The place's locality, muted beside its name. Never wraps; the name truncates first.
    var suburb: String?
    var meta: Meta
    /// The person's own words, with their tokens. Empty when the surface leaves them to the entry
    /// (``SlipAnatomy/showsWords(on:dishCount:)``).
    var words: EntryComposition
    var photos: [AtePhoto]
    /// Who wrote it — present in the feed, absent in your own journal and on their own profile.
    var byline: AteByline?

    init(
        id: UUID = UUID(),
        dishes: [Dish] = [],
        place: String? = nil,
        placeID: UUID? = nil,
        suburb: String? = nil,
        meta: Meta = .none,
        words: EntryComposition,
        photos: [AtePhoto] = [],
        byline: AteByline? = nil
    ) {
        self.id = id
        self.dishes = dishes
        self.place = place
        self.placeID = placeID
        self.suburb = suburb
        self.meta = meta
        self.words = words
        self.photos = photos
        self.byline = byline
    }
}

/// Who wrote an entry, for a feed slip's identity strip.
struct AteByline: Equatable {
    var userID: UUID
    var handle: String
    /// "2h", "1d" — already written, because how an age is worded is a product decision
    /// (``RelativeAge``), not a view's.
    var age: String
}
