import Foundation

/// **Where the Feed opens** (pattern contract §6, Eamon 3 Oct: "the Feed opens on the city of your
/// Journal"). A person who has never picked is not asked for their location on open: the Feed reads
/// the city their own entries are mostly in, and location is asked for only when they tap Near me.
///
/// Set ``FeedAreaModel/opening`` and every first read (``FeedAreaModel/cityForFirstPage(wait:)``)
/// settles it once before it reads. A stored pick always wins, and the opening is never stored.
extension FeedAreaModel {
    /// The rule: the Journal's busiest city, else the busiest city with food, else everywhere.
    public nonisolated static func openingLocation(journalCities: [AteCity], feedCities: [AteCity]) -> FeedLocation {
        if let city = AteCity.ordered(journalCities).first { return .city(city.city) }
        if let city = AteCity.ordered(feedCities).first { return .city(city.city) }
        return .everywhere
    }

    /// Settles where the Feed opens, once: nothing to do after a pick or with no ``opening``; a
    /// second caller waits on the first.
    public func openIfNeeded() async {
        guard let opening, hasChosenLocation == false else {
            hasOpened = true
            return
        }
        if let openingTask {
            await openingTask.value
            return
        }
        let task = Task { @MainActor [weak self] in
            let next = await opening()
            guard let self else { return }
            // A pick made while the opening was being worked out wins.
            if self.hasChosenLocation == false { self.location = next }
            self.hasOpened = true
        }
        openingTask = task
        await task.value
    }
}
