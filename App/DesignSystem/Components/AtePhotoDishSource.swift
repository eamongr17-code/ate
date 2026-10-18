import SwiftUI

/// Which dish each of an entry's photos is, as the viewer needs it.
struct AtePhotoDishes: Sendable {
    /// The entry's dishes, in receipt order.
    var choices: [AtePhotoDishPill.Dish]
    /// Photo URL → dish (review) id.
    var paired: [String: UUID]
    /// The author fixing one: the photo's URL and the dish, or `nil` for No dish. Answers whether it
    /// held. `nil` on anybody else's entry: the pill only names.
    var onPick: (@MainActor @Sendable (String, UUID?) async -> Bool)?
    /// Reads the pairs as they stand now, once the viewer is up: a list's slip has none in hand, and
    /// a match that lands while the entry is open shows without reopening it (14 Oct).
    var load: (@MainActor @Sendable () async -> [String: UUID])?
    /// Who and where, under the dish on somebody else's photo: "@paris · 400 Gradi".
    var byline: String?
    /// Photo URL → its own byline, where one viewer holds several people's photos (a dish page's
    /// hero). Falls back to ``byline``.
    var bylines: [String: String] = [:]

    /// Photos that are all one dish — a dish page's hero, a menu row's cover: each is named by it,
    /// as a caption, wherever it opens (18 Oct: every full-screen photo names its dish).
    static func one(
        _ name: String, photos: [AtePhoto], byline: String?, bylines: [String: String] = [:]
    ) -> AtePhotoDishes? {
        let urls = photos.compactMap { $0.url?.absoluteString }
        guard name.isEmpty == false, urls.isEmpty == false else { return nil }
        let dish = AtePhotoDishPill.Dish(id: UUID(), name: name)
        return AtePhotoDishes(
            choices: [dish],
            paired: Dictionary(urls.map { ($0, dish.id) }, uniquingKeysWith: { first, _ in first }),
            byline: byline,
            bylines: bylines
        )
    }
}

/// Where a slip's photos learn their dishes (0063). The shell sets it from the entry service, so a
/// photo opened from the journal, the feed or a profile is named like one opened on its entry.
struct AtePhotoDishSource: Sendable {
    /// Photo URL → review id for an entry; for one never matched (anyone's), it asks for a match first.
    var pairs: @MainActor @Sendable (_ entryID: UUID, _ isMine: Bool) async -> [String: UUID]
    /// Your own fix: this photo is this dish, or no dish. Answers whether it held.
    var pick: @MainActor @Sendable (_ entryID: UUID, _ url: String, _ reviewID: UUID?) async -> Bool

    /// The photos of a slip, with its dishes, for the viewer. `nil` with no dishes to name.
    @MainActor
    func dishes(for slip: AteSlip) -> AtePhotoDishes? {
        guard slip.dishes.isEmpty == false else { return nil }
        let entryID = slip.id
        let isMine = slip.isMine
        let pick = self.pick
        let pairs = self.pairs
        var onPick: (@MainActor @Sendable (String, UUID?) async -> Bool)?
        if isMine {
            onPick = { (url: String, reviewID: UUID?) async -> Bool in await pick(entryID, url, reviewID) }
        }
        return AtePhotoDishes(
            choices: slip.dishes.map { AtePhotoDishPill.Dish(id: $0.id, name: $0.name) },
            paired: [:],
            onPick: onPick,
            load: { await pairs(entryID, isMine) },
            byline: AtePhotoDishByline.line(who: slip.byline?.name, place: slip.place)
        )
    }
}

extension EnvironmentValues {
    @Entry var atePhotoDishSource: AtePhotoDishSource?
}
