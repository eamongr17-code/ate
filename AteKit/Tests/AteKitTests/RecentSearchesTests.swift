import Foundation
import Testing

@testable import AteKit

@MainActor
@Suite("Search — recent searches")
struct RecentSearchesTests {
    private let owner = UUID()

    private func defaults() -> UserDefaults {
        let name = "recents.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test("newest first, and searching the same words again moves them to the top")
    func newestFirstWithoutRepeats() {
        let recents = RecentSearches(owner: owner, defaults: defaults())
        recents.record("ragu", scope: .dishes)
        recents.record("Tipo 00", scope: .places)
        recents.record("Ragu", scope: .dishes)
        #expect(recents.items.map(\.text) == ["Ragu", "Tipo 00"])
    }

    @Test("a keystroke below the search's floor is not a search")
    func tooShortIsNotRemembered() {
        let recents = RecentSearches(owner: owner, defaults: defaults())
        recents.record(" r ", scope: .dishes)
        recents.record("   ", scope: .people)
        #expect(recents.items.isEmpty)
    }

    @Test("kept to the limit, oldest dropped")
    func capped() {
        let recents = RecentSearches(owner: owner, defaults: defaults(), limit: 3)
        for word in ["one", "two", "three", "four"] { recents.record(word, scope: .dishes) }
        #expect(recents.items.map(\.text) == ["four", "three", "two"])
    }

    @Test("kept on the phone per person: the next person signing in starts empty")
    func perPerson() {
        let store = defaults()
        let mine = RecentSearches(owner: owner, defaults: store)
        mine.record("pho", scope: .dishes)
        mine.record("@jessw", scope: .people)

        #expect(RecentSearches(owner: owner, defaults: store).items.map(\.text) == ["@jessw", "pho"])
        #expect(RecentSearches(owner: UUID(), defaults: store).items.isEmpty)
        #expect(RecentSearches(owner: nil, defaults: store).items.isEmpty)
    }

    @Test("removing one and clearing all are remembered too")
    func removeAndClear() {
        let store = defaults()
        let recents = RecentSearches(owner: owner, defaults: store)
        recents.record("pho", scope: .dishes)
        recents.record("laksa", scope: .dishes)
        recents.remove(RecentSearch(text: "PHO", scope: .places))
        #expect(RecentSearches(owner: owner, defaults: store).items.map(\.text) == ["laksa"])
        recents.clear()
        #expect(RecentSearches(owner: owner, defaults: store).items.isEmpty)
    }
}
