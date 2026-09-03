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

    @Test("the entry view's events carry the review, the dish and whether it was a sitting")
    func entryViewEvents() {
        let reviewID = UUID()
        let dishID = UUID()
        let viewed = DiaryEvents.diaryEntryViewed(reviewID: reviewID, dishID: dishID, isMultiDishSitting: true)
        #expect(viewed.name == "diary_entry_viewed")
        #expect(viewed.parameters == [
            "review_id": reviewID.uuidString.lowercased(),
            "dish_id": dishID.uuidString.lowercased(),
            "is_multi_dish_sitting": "true"
        ])

        let single = DiaryEvents.diaryEntryViewed(reviewID: reviewID, dishID: dishID, isMultiDishSitting: false)
        #expect(single.parameters["is_multi_dish_sitting"] == "false")

        let opened = DiaryEvents.diaryEntryDishOpened(dishID: dishID)
        #expect(opened.name == "diary_entry_dish_opened")
        #expect(opened.parameters == ["dish_id": dishID.uuidString.lowercased()])
    }

    @Test("Rule R reports every site it is used at, and only those")
    func restaurantNameTapped() {
        #expect(DiaryEvents.restaurantNameTapped(from: .feedRow).name == "restaurant_name_tapped")
        #expect(RestaurantLinkOrigin.allCases.map(\.rawValue).sorted() == [
            "diary_entry", "diary_sitting", "dish_detail", "feed_row", "receipt"
        ])
        for origin in RestaurantLinkOrigin.allCases {
            #expect(DiaryEvents.restaurantNameTapped(from: origin).parameters == ["from": origin.rawValue])
        }
    }
}
