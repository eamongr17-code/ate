import AteKit
import SwiftUI

/// Which dishes each of an entry's photos shows, as the viewer needs it.
struct AtePhotoDishes: Sendable {
    /// The entry's dishes, in receipt order.
    var choices: [AtePhotoDishPill.Dish]
    /// Photo URL → the dishes in it, each with where it sits when the matcher placed it (0083).
    var paired: [String: [PhotoDishTag]]
    /// The author fixing one: the photo's URL and every dish in it (empty for No dish). Answers
    /// whether it held. `nil` on anybody else's entry: the pill only names.
    var onPick: (@MainActor @Sendable (String, [UUID]) async -> Bool)?
    /// Reads the pairs as they stand now, once the viewer is up: a list's slip has none in hand, and
    /// a match that lands while the entry is open shows without reopening it (14 Oct).
    var load: (@MainActor @Sendable () async -> [String: [PhotoDishTag]])?
    /// Who and where, under the dish on somebody else's photo: "@paris · 400 Gradi".
    var byline: String?
    /// Photo URL → its own byline, where one viewer holds several people's photos (a dish page's
    /// hero). Falls back to ``byline``.
    var bylines: [String: String] = [:]
    /// The dish a shared photo opens on: its name is already up and the caption names it alone (a
    /// dish page's hero, 0083).
    var focus: UUID?

    /// The dishes a photo shows, in receipt order, each once.
    func dishes(in url: String, paired: [String: [PhotoDishTag]]) -> [AtePhotoDishPill.Dish] {
        let ids = Set((paired[url] ?? []).map(\.reviewID))
        return choices.filter { ids.contains($0.id) }
    }

    /// Photos that are all one dish — a dish page's hero, a menu row's cover: each is named by it,
    /// as a caption, wherever it opens (18 Oct: every full-screen photo names its dish). `shared`:
    /// a photo this dish shares with others, where it sits and the others placed beside it (0083).
    static func one(
        _ name: String, photos: [AtePhoto], byline: String?, bylines: [String: String] = [:],
        shared: [String: (box: PhotoDishBox, others: [DishPhoto.Other])] = [:]
    ) -> AtePhotoDishes? {
        let urls = photos.compactMap { $0.url?.absoluteString }
        guard name.isEmpty == false, urls.isEmpty == false else { return nil }
        let dish = AtePhotoDishPill.Dish(id: UUID(), name: name)
        var choices = [dish]
        var paired: [String: [PhotoDishTag]] = [:]
        for url in urls where paired[url] == nil {
            guard let here = shared[url] else {
                paired[url] = [PhotoDishTag(reviewID: dish.id)]
                continue
            }
            var tags = [PhotoDishTag(reviewID: dish.id, box: here.box)]
            for other in here.others {
                // One choice per name: the same side dish in two photos is one dish.
                let choice = choices.first { $0.name == other.name }
                    ?? AtePhotoDishPill.Dish(id: UUID(), name: other.name)
                if choices.contains(choice) == false { choices.append(choice) }
                tags.append(PhotoDishTag(reviewID: choice.id, box: other.box))
            }
            paired[url] = tags
        }
        return AtePhotoDishes(
            choices: choices, paired: paired, byline: byline, bylines: bylines, focus: shared.isEmpty ? nil : dish.id
        )
    }
}

/// Where a slip's photos learn their dishes (0063). The shell sets it from the entry service, so a
/// photo opened from the journal, the feed or a profile is named like one opened on its entry.
struct AtePhotoDishSource: Sendable {
    /// Photo URL → its dishes for an entry; for one never matched (anyone's), or matched before
    /// dishes were placed, it asks for a match first.
    var pairs: @MainActor @Sendable (_ entryID: UUID, _ isMine: Bool) async -> [String: [PhotoDishTag]]
    /// Your own fix: this photo is these dishes, or none. Answers whether it held.
    var pick: @MainActor @Sendable (_ entryID: UUID, _ url: String, _ reviewIDs: [UUID]) async -> Bool
    /// The pairs last read for an entry, so a photo opened again is named as it lands rather than
    /// a round trip later (24 Oct). The viewer still reads them afresh behind it.
    var known: @MainActor @Sendable (_ entryID: UUID) -> [String: [PhotoDishTag]]? = { _ in nil }

    /// The photos of a slip, with its dishes, for the viewer. `nil` with no dishes to name.
    @MainActor
    func dishes(for slip: AteSlip) -> AtePhotoDishes? {
        guard slip.dishes.isEmpty == false else { return nil }
        let entryID = slip.id
        let isMine = slip.isMine
        let pick = self.pick
        let pairs = self.pairs
        var onPick: (@MainActor @Sendable (String, [UUID]) async -> Bool)?
        if isMine {
            onPick = { (url: String, reviewIDs: [UUID]) async -> Bool in await pick(entryID, url, reviewIDs) }
        }
        return AtePhotoDishes(
            choices: slip.dishes.map { AtePhotoDishPill.Dish(id: $0.id, name: $0.name) },
            paired: known(entryID) ?? [:],
            onPick: onPick,
            load: { await pairs(entryID, isMine) },
            byline: AtePhotoDishByline.line(who: slip.byline?.name, place: slip.place)
        )
    }
}

extension EnvironmentValues {
    @Entry var atePhotoDishSource: AtePhotoDishSource?
}
