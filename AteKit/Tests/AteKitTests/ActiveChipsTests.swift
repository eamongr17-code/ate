import Foundation
import Testing
@testable import AteKit

/// The chips the Journal shows under its bar only while a filter is on.
@Suite("Active chips")
struct ActiveChipsTests {

    @Test("nothing on: no chips, on either shelf")
    func restingChips() {
        #expect(BrowseFilters().activeChips(on: .journal).isEmpty)
        #expect(BrowseFilters().activeChips(on: .saved).isEmpty)
        #expect(BrowseFilters().isFiltering(on: .journal) == false)
    }

    @Test("only the filters that are on show, in the sheet's order; Saved never shows the order")
    func activeChips() {
        let filters = BrowseFilters(sort: .top, band: ScoreBand.Preset.fourPlus.band, city: "melbourne")
        #expect(filters.activeChips(on: .journal) == [.sort, .rating, .city])
        #expect(filters.activeChips(on: .saved) == [.rating, .city])
        let sortOnly = BrowseFilters(sort: .oldest)
        #expect(sortOnly.isFiltering(on: .journal))
        #expect(sortOnly.isFiltering(on: .saved) == false)
    }
}
