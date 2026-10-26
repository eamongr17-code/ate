import Foundation
import Observation

/// **Your own saved dishes** — one list, read whole (at most 500), newest first. Adding is a round trip
/// (the place and the id are the server's); removing is optimistic, with an undo that adds the dish
/// back as it was. A refusal puts things back and sets ``failed``.
@MainActor
@Observable
public final class OwnSavesStore {
    public private(set) var saves: [OwnSave] = []
    public private(set) var hasLoaded = false
    public private(set) var failed = false
    /// The last one removed from the shelf, until its Undo expires.
    public private(set) var undoable: OwnSave?

    @ObservationIgnored private let service: any OwnSaving
    @ObservationIgnored private let analytics: AnalyticsRecorder
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var generation = 0

    public init(
        service: any OwnSaving,
        analytics: @escaping AnalyticsRecorder = { _ in },
        now: @escaping () -> Date = Date.init
    ) {
        self.service = service
        self.analytics = analytics
        self.now = now
    }

    public func loadIfNeeded() async {
        guard hasLoaded == false else { return }
        await refresh()
    }

    public func refresh() async {
        generation += 1
        let generationAtStart = generation
        do {
            let rows = try await service.ownSaves()
            guard generationAtStart == generation else { return }
            saves = rows
            hasLoaded = true
            failed = false
        } catch {
            guard generationAtStart == generation else { return }
            if hasLoaded == false { failed = true }
        }
    }

    /// Adds it and reads the list back, so the new row arrives with the server's own place name.
    /// `false` when the server refused it.
    @discardableResult
    public func add(_ draft: OwnSaveDraft, from origin: OwnSaveEvents.Origin) async -> Bool {
        do {
            let id = try await service.add(draft)
            // Shown at once, then replaced by the server's row on the read back.
            let made = OwnSave(
                id: id, dishName: draft.trimmedDishName ?? draft.dishName, restaurantID: draft.restaurantID,
                restaurantName: draft.restaurantName, source: draft.source, sourceURL: draft.cleanLink,
                sourceAuthor: draft.author, sourceCaption: draft.caption, createdAt: now()
            )
            generation += 1
            saves.removeAll { $0.id == id }
            saves.insert(made, at: 0)
            hasLoaded = true
            analytics(OwnSaveEvents.added(source: draft.source, origin: origin))
            await refresh()
            return true
        } catch {
            return false
        }
    }

    /// The bookmark on the shelf: gone at once, with an Undo.
    public func remove(_ save: OwnSave) async {
        guard let index = saves.firstIndex(of: save) else { return }
        generation += 1
        saves.remove(at: index)
        do {
            try await service.remove(id: save.id)
            // Offered only once the row is really gone, so an Undo can never race the remove.
            undoable = save
            analytics(OwnSaveEvents.removed(source: save.source))
        } catch {
            saves.insert(save, at: min(index, saves.count))
        }
    }

    /// Puts the last removed one back — a new row with the same dish, place and link.
    public func undoRemove() async {
        guard let save = undoable else { return }
        undoable = nil
        let draft = OwnSaveDraft(
            dishName: save.dishName, restaurantID: save.restaurantID, restaurantName: save.restaurantName,
            link: save.sourceURL, author: save.sourceAuthor, caption: save.sourceCaption
        )
        guard (try? await service.add(draft)) != nil else { return }
        await refresh()
    }

    public func expireUndo(for save: OwnSave) {
        if undoable == save { undoable = nil }
    }

    /// "I ate it", once its entry is saved: it leaves Saved for the Journal. Quiet on a refusal — the
    /// entry is what mattered, and the dish can be taken off by hand.
    public func fulfil(id: UUID) async {
        let removed = saves.first { $0.id == id }
        generation += 1
        saves.removeAll { $0.id == id }
        guard (try? await service.remove(id: id)) != nil else {
            if let removed {
                saves.append(removed)
                saves.sort { $0.createdAt > $1.createdAt }
            }
            return
        }
        analytics(OwnSaveEvents.eaten(source: removed?.source ?? .manual))
    }
}

/// **The Saved shelf, both kinds in one order** — newest first. Saves from Ate arrive a page at a
/// time, so an own save older than the last Ate row loaded waits until that page is in (or the Ate
/// list has ended); nothing ever jumps in above what is already on screen.
public enum SavedShelf {
    public enum Row: Sendable, Hashable, Identifiable {
        case ate(SavedDish)
        case own(OwnSave)

        public var id: String {
            switch self {
            case .ate(let dish): "ate-\(dish.dishID.uuidString)"
            case .own(let save): "own-\(save.id.uuidString)"
            }
        }

        public var date: Date {
            switch self {
            case .ate(let dish): dish.savedAt
            case .own(let save): save.createdAt
            }
        }
    }

    public static func rows(ate: [SavedDish], own: [OwnSave], ateHasReachedEnd: Bool) -> [Row] {
        let floor = ateHasReachedEnd ? nil : ate.last?.savedAt
        let shown = own.filter { save in floor.map { save.createdAt >= $0 } ?? true }
        return (ate.map(Row.ate) + shown.map(Row.own)).sorted { lhs, rhs in
            lhs.date == rhs.date ? lhs.id > rhs.id : lhs.date > rhs.date
        }
    }
}

/// **Your own saves, counted.** Sent by the app's recorder.
public enum OwnSaveEvents {
    /// Where an own save was made.
    public enum Origin: String, Sendable {
        /// The + on Saved.
        case saved
        /// The share sheet, from another app.
        case shareExtension = "share_extension"
    }

    public static func added(source: OwnSaveSource, origin: Origin) -> AnalyticsEvent {
        AnalyticsEvent(
            name: "own_save_added",
            parameters: ["source": source.rawValue, "origin": origin.rawValue]
        )
    }

    public static func removed(source: OwnSaveSource) -> AnalyticsEvent {
        AnalyticsEvent(name: "own_save_removed", parameters: ["source": source.rawValue])
    }

    public static func opened(source: OwnSaveSource) -> AnalyticsEvent {
        AnalyticsEvent(name: "own_save_opened", parameters: ["source": source.rawValue])
    }

    /// "I ate it" tapped: the composer opens on the dish.
    public static func ateItTapped(source: OwnSaveSource) -> AnalyticsEvent {
        AnalyticsEvent(name: "own_save_ate_it", parameters: ["source": source.rawValue])
    }

    /// The entry "I ate it" opened was saved, and the dish left Saved.
    public static func eaten(source: OwnSaveSource) -> AnalyticsEvent {
        AnalyticsEvent(name: "own_save_eaten", parameters: ["source": source.rawValue])
    }

    public static func linkOpened(source: OwnSaveSource) -> AnalyticsEvent {
        AnalyticsEvent(name: "own_save_link_opened", parameters: ["source": source.rawValue])
    }
}

/// Own saves in memory — previews, tests, the preview drive.
public actor InMemoryOwnSaves: OwnSaving {
    /// A place the in-memory server knows by name.
    public struct Place: Sendable {
        public let name: String
        public let city: String?

        public init(name: String, city: String? = nil) {
            self.name = name
            self.city = city
        }
    }

    private var rows: [OwnSave]
    private let places: [UUID: Place]
    private var failsNextWrite = false

    public init(rows: [OwnSave] = [], places: [UUID: Place] = [:]) {
        self.rows = rows
        self.places = places
    }

    /// The next add or remove is refused.
    public func failNextWrite() {
        failsNextWrite = true
    }

    public func ownSaves() async throws -> [OwnSave] {
        rows.sorted { $0.createdAt > $1.createdAt }
    }

    public func add(_ draft: OwnSaveDraft) async throws -> UUID {
        try refuseIfAsked()
        guard let name = draft.trimmedDishName else { throw OwnSaveError.invalidName }
        let id = UUID()
        let place = places[draft.restaurantID]
        rows.append(OwnSave(
            id: id, dishName: name, restaurantID: draft.restaurantID,
            restaurantName: place?.name ?? draft.restaurantName, restaurantCity: place?.city,
            source: draft.source, sourceURL: draft.cleanLink, sourceAuthor: draft.author,
            sourceCaption: draft.caption, createdAt: Date()
        ))
        return id
    }

    public func remove(id: UUID) async throws {
        try refuseIfAsked()
        rows.removeAll { $0.id == id }
    }

    private func refuseIfAsked() throws {
        guard failsNextWrite else { return }
        failsNextWrite = false
        throw OwnSaveError.refused
    }
}

extension InMemoryOwnSaves {
    /// The preview drive's own saves: one of each source.
    public static func preview(now: Date = Date()) -> InMemoryOwnSaves {
        let ago = { (hours: Double) in now.addingTimeInterval(-hours * 3600) }
        return InMemoryOwnSaves(rows: [
            OwnSave(
                id: .fixture("own.Crab fried rice"), dishName: "Crab fried rice", restaurantID: .fixture("place.Ho Jiak"),
                restaurantName: "Ho Jiak",
                restaurantCity: "Sydney", source: .tiktok,
                sourceURL: "https://www.tiktok.com/@sydneyeats/video/7300000000000000000",
                sourceAuthor: "@sydneyeats", sourceCaption: "The crab fried rice at Ho Jiak is unreal",
                createdAt: ago(1)
            ),
            OwnSave(
                id: .fixture("own.Birria tacos"), dishName: "Birria tacos", restaurantID: .fixture("place.La Tortilleria"),
                restaurantName: "La Tortilleria",
                restaurantCity: "Melbourne", source: .instagram,
                sourceURL: "https://www.instagram.com/reel/C1abc/", createdAt: ago(30)
            ),
            OwnSave(
                id: .fixture("own.Duck pancakes"), dishName: "Duck pancakes", restaurantID: .fixture("place.Flower Drum"),
                restaurantName: "Flower Drum",
                restaurantCity: "Melbourne", createdAt: ago(80)
            ),
            OwnSave(
                id: .fixture("own.Khao soi"), dishName: "Khao soi", restaurantID: .fixture("place.Soi 38"),
                restaurantName: "Soi 38",
                restaurantCity: "Melbourne", source: .link,
                sourceURL: "https://www.broadsheet.com.au/melbourne/food-and-drink", createdAt: ago(200)
            )
        ])
    }
}
