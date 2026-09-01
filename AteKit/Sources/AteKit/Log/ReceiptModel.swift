import Foundation

/// Everything the receipt renders, decided once and shared by the on-screen presentation AND the
/// exported image (§5.2). Two renderers, one content model — a screenshot and a share image that
/// disagree would be the loop's worst bug.
public struct ReceiptModel: Sendable, Hashable {
    /// One dish on the receipt. Multi-dish sittings render one row each, single-dish gets the hero
    /// treatment — same data either way.
    public struct Line: Sendable, Hashable, Identifiable {
        public let id: UUID
        public let dishID: UUID
        public let dishName: String
        public let score: Rating
        /// The LOCAL staged photo (§5.4): server-side processing may not have finished, and the
        /// receipt must never wait on it.
        public let photoFileName: String?

        public init(id: UUID, dishID: UUID, dishName: String, score: Rating, photoFileName: String? = nil) {
            self.id = id
            self.dishID = dishID
            self.dishName = dishName
            self.score = score
            self.photoFileName = photoFileName
        }
    }

    public struct Author: Sendable, Hashable {
        public let name: String
        public let handle: String
        public let avatarURLString: String?

        public init(name: String, handle: String, avatarURLString: String? = nil) {
            self.name = name
            self.handle = handle
            self.avatarURLString = avatarURLString
        }
    }

    public let restaurantName: String
    public let suburb: String?
    public let lines: [Line]
    public let author: Author?
    public let date: Date

    public init(
        restaurantName: String,
        suburb: String?,
        lines: [Line],
        author: Author?,
        date: Date = Date()
    ) {
        self.restaurantName = restaurantName
        self.suburb = suburb
        self.lines = lines
        self.author = author
        self.date = date
    }

    /// Built from the sitting that was just posted. Unrated cards can't exist at this point (Post is
    /// gated on §4.3), and are dropped rather than rendered as a gap.
    public init(sitting: SittingState, author: Author?, date: Date = Date()) {
        self.init(
            restaurantName: sitting.restaurant.name,
            suburb: sitting.restaurant.suburb,
            lines: sitting.dishes.compactMap { dish in
                guard let score = dish.score else { return nil }
                return Line(
                    id: dish.id,
                    dishID: dish.dishID,
                    dishName: dish.dishName,
                    score: score,
                    photoFileName: dish.photo?.localFileName
                )
            },
            author: author,
            date: date
        )
    }

    public var isSingleDish: Bool { lines.count == 1 }

    /// The single-dish hero score. Multi-dish receipts print each line's score instead — there is no
    /// "average of my sitting", because a sitting isn't a thing anyone rates.
    public var heroScore: Rating? { isSingleDish ? lines.first?.score : nil }

    /// `Chin Chin · Melbourne`, or just the name.
    public var placeLine: String {
        guard let suburb, !suburb.isEmpty else { return restaurantName }
        return "\(restaurantName) · \(suburb)"
    }

    /// §5.3: when `ImageRenderer` fails, the share degrades to this — never to an error dialog.
    public var shareText: String {
        let dishes = lines
            .map { "\($0.dishName) \(ScoreFormat.outOfFive($0.score.value))" }
            .joined(separator: ", ")
        return "\(dishes) at \(placeLine)"
    }

    /// The share sheet's preview title.
    public var shareTitle: String {
        lines.first.map { isSingleDish ? $0.dishName : "\($0.dishName) + \(lines.count - 1) more" }
            ?? restaurantName
    }

    /// §5.2: "View dish" is offered for single-dish sittings only.
    public var singleDishRoute: DishRoute? {
        isSingleDish ? lines.first.map { DishRoute(dishID: $0.dishID) } : nil
    }
}
