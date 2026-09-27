import Foundation
import Observation

/// **A list of cities a filter offers** — the Journal's (`my_entry_cities`), the shelf's
/// (`my_saved_cities`), Search's (`search_cities`) and the Feed's (`feed_cities`), read the same way:
/// ahead of the sheet, so it rises full (#83's rule), with a read already in the air joined rather
/// than repeated. A failure still answers the sheet (it keeps the last list, and Everywhere) and is
/// asked again next time.
@MainActor
@Observable
public final class AteCityList {
    public private(set) var cities: [AteCity] = []
    /// Whether the list has answered once — until it has, the sheet draws still pills.
    public private(set) var hasLoaded = false

    @ObservationIgnored private let read: @MainActor () async throws -> [AteCity]
    @ObservationIgnored private var inFlight: Task<Void, Never>?
    @ObservationIgnored private var failed = false

    public init(read: @escaping @MainActor () async throws -> [AteCity]) {
        self.read = read
    }

    /// Reads the list afresh (or joins the read in the air).
    public func load() async {
        if let inFlight {
            await inFlight.value
            return
        }
        let task = Task { [weak self] in
            guard let self else { return }
            let list = try? await self.read()
            self.failed = list == nil
            if let list { self.cities = list }
            self.hasLoaded = true
        }
        inFlight = task
        await task.value
        inFlight = nil
    }

    /// Reads it only if it has not answered yet, or last time failed — what a sheet waits on.
    public func loadIfNeeded() async {
        guard inFlight != nil || hasLoaded == false || failed else { return }
        await load()
    }
}
