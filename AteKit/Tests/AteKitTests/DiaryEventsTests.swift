import Foundation
import Testing

@testable import AteKit

@Suite("Diary funnel events")
struct DiaryEventsTests {
    @Test("event names and parameter keys are the ones the funnel is defined on")
    func eventContract() {
        #expect(DiaryEvents.diaryViewed().name == "diary_viewed")
        #expect(DiaryEvents.diaryViewed().parameters.isEmpty)

        let dishID = UUID()
        let tap = DiaryEvents.diaryEntryTapped(dishID: dishID)
        #expect(tap.name == "diary_entry_tapped")
        #expect(tap.parameters == ["dish_id": dishID.uuidString.lowercased()])
    }

    @Test("ids are lowercased so an event value pastes straight into a Postgres query")
    func identifiersMatchPostgres() {
        let value = DiaryEvents.diaryEntryTapped(dishID: UUID()).parameters["dish_id"]
        #expect(value == value?.lowercased())
        #expect(value?.contains("-") == true)
    }
}
