import SwiftUI

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
