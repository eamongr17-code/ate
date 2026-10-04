import Foundation
import Observation

/// **Under an entry's paper** (build 87, note 8): "More at <place>" — that place's best dishes the
/// entry did not log — and "More like this" — the dishes most like the entry's best one, the same
/// `similar_dishes` read a dish page's "More like this" makes.
///
/// Read after the entry has printed, both at once; each section settles on its own answer. A section
/// with nothing in it, or whose read fell over, is not on the page at all — no error line.
@MainActor
@Observable
public final class EntryMoreStore {
    /// Which shelf a card was on — `entry_more_opened`'s `section`.
    public enum Section: String, Sendable, CaseIterable, Codable {
        case place
        case similar
    }

    /// What the two reads are asked about, drawn from the printed entry.
    public struct Subject: Sendable, Hashable {
        public let restaurantID: UUID?
        /// The dish "More like this" is like.
        public let anchorDishID: UUID?
        /// The entry's own dishes: never offered back to it.
        public let ownDishIDs: Set<UUID>
        /// Their names, folded: at the same place a dish of the same name is the same dish, even
        /// where two rows of it have not been merged into one id.
        public let ownDishNames: Set<String>

        public init(restaurantID: UUID?, anchorDishID: UUID?, ownDishIDs: Set<UUID>, ownDishNames: Set<String> = []) {
            self.restaurantID = restaurantID
            self.anchorDishID = anchorDishID
            self.ownDishIDs = ownDishIDs
            self.ownDishNames = Set(ownDishNames.map(EntryMoreStore.fold))
        }

        /// `nil` while the entry has no dishes yet (it is still sorting): nothing to read about.
        public init?(_ card: EntryCard) {
            guard card.items.isEmpty == false else { return nil }
            self.init(
                restaurantID: card.restaurantID,
                anchorDishID: EntryMoreStore.anchor(card.items),
                ownDishIDs: Set(card.items.map(\.dishID)),
                ownDishNames: Set(card.items.map(\.dishName))
            )
        }
    }

    /// A shelf holds this many cards at most.
    public nonisolated static let cap = 10
    /// How much of the menu is read to find ten the entry did not log.
    nonisolated static let menuPage = 50

    public private(set) var atPlace: [MenuDish] = []
    public private(set) var similar: [SimilarDish] = []
    public private(set) var isPlaceSettled = false
    public private(set) var isSimilarSettled = false
    public private(set) var subject: Subject?

    private let places: any PlacePageReading
    private let explore: any DishExploreReading

    public init(places: any PlacePageReading, explore: any DishExploreReading) {
        self.places = places
        self.explore = explore
    }

    /// "More at" is on the page while it is read, then only with a card in it — and never for an
    /// entry with no place (a place is never assumed).
    public var showsPlace: Bool {
        guard subject?.restaurantID != nil else { return false }
        return isPlaceSettled == false || atPlace.isEmpty == false
    }

    public var showsSimilar: Bool {
        guard subject?.anchorDishID != nil else { return false }
        return isSimilarSettled == false || similar.isEmpty == false
    }

    /// Read for this entry. A second call about the same subject reads nothing; a changed entry (a
    /// place attached, a dish corrected) reads again.
    public func load(_ subject: Subject?) async {
        guard let subject, subject != self.subject else { return }
        self.subject = subject
        atPlace = []
        similar = []
        isPlaceSettled = subject.restaurantID == nil
        isSimilarSettled = subject.anchorDishID == nil
        // Each shelf settles on its own answer.
        async let place: Void = readPlace(subject)
        async let like: Void = readSimilar(subject)
        _ = await (place, like)
        // Taken away mid-read (the page was popped): the next visit asks again.
        if Task.isCancelled, subject == self.subject, isPlaceSettled == false || isSimilarSettled == false {
            self.subject = nil
        }
    }

    private func readPlace(_ subject: Subject) async {
        guard let id = subject.restaurantID else { return }
        let places = places
        let rows = try? await places.placeDishes(restaurantID: id, after: nil, pageSize: Self.menuPage).items
        guard Task.isCancelled == false, subject == self.subject else { return }
        atPlace = Self.best(rows ?? [], excluding: subject.ownDishIDs, named: subject.ownDishNames)
        isPlaceSettled = true
    }

    private func readSimilar(_ subject: Subject) async {
        guard let id = subject.anchorDishID else { return }
        let explore = explore
        let rows = try? await explore.similarDishes(dishID: id, limit: Self.cap + subject.ownDishIDs.count)
        guard Task.isCancelled == false, subject == self.subject else { return }
        similar = Self.others(rows ?? [], excluding: subject.ownDishIDs)
        isSimilarSettled = true
    }

    // MARK: - The rules

    /// The entry's highest-scored dish (a secret 6 above a 5; the earlier line on a tie); with
    /// nothing scored, its first dish. Never a guessed score.
    public nonisolated static func anchor(_ items: [EntryCard.Item]) -> UUID? {
        let ordered = items.sorted { $0.position < $1.position }
        let best = ordered.reduce(into: EntryCard.Item?.none) { best, item in
            guard let score = item.score else { return }
            if let current = best?.score, current >= score { return }
            best = item
        }
        return (best ?? ordered.first)?.dishID
    }

    /// The place's best, in the server's order (`place_dishes` ranks by rating since 0051; a paged
    /// list is never reordered on arrival) — without the entry's own dishes or a repeat, ten at most.
    public nonisolated static func best(
        _ menu: [MenuDish], excluding own: Set<UUID>, named names: Set<String> = []
    ) -> [MenuDish] {
        var seen = own
        let folded = Set(names.map(fold))
        return Array(menu.filter {
            folded.contains(fold($0.name)) == false && seen.insert($0.dishID).inserted
        }.prefix(cap))
    }

    /// A dish name as compared: case, accents and outer spaces aside.
    nonisolated static func fold(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    /// The server's ranking, without the entry's own dishes or a repeat, ten at most.
    public nonisolated static func others(_ rows: [SimilarDish], excluding own: Set<UUID>) -> [SimilarDish] {
        var seen = own
        return Array(rows.filter { seen.insert($0.dishID).inserted }.prefix(cap))
    }
}
