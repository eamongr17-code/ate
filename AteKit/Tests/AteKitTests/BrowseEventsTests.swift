import Foundation
import Testing
@testable import AteKit

@MainActor
@Suite("Browse events")
struct BrowseEventsTests {
    @Test("journal_queried names the filters in use and never their values")
    func queriedEvent() {
        let event = BrowseEvents.journalQueried(
            JournalQuery(sort: .oldest, place: JournalPlace(restaurantID: UUID(), name: "Secret"), tag: .df),
            resultCount: 7
        )
        #expect(event.name == "journal_queried")
        #expect(event.parameters == ["sort": "oldest", "filters": "place,tag", "result_count": "7"])
        #expect(event.parameters.values.contains("Secret") == false)
    }

    @Test("the photo viewer, the one filter sheet and the entry page report what they need")
    func otherEvents() {
        #expect(BrowseEvents.photoPreviewOpened(photoCount: 3).parameters == ["photo_count": "3"])
        let journal = BrowseEvents.filterOpened(on: .journal)
        #expect(journal.name == "filter_opened" && journal.parameters == ["surface": "journal"])
        #expect(BrowseEvents.filterOpened(on: .search).parameters == ["surface": "search"])
        #expect(BrowseEvents.entryOpened(seeded: true).parameters == ["seeded": "true"])
    }
}
