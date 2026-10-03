import Foundation
import Testing
@testable import AteKit

/// The Journal's calendar as a zoom (list, month, year), and the chips the rebuilt Journal shows
/// only while a filter is on.
@Suite("Journal zoom and active chips")
struct JournalZoomTests {

    @Test("the calendar button steps out, and from the year back to the list")
    func button() {
        #expect(JournalZoom.list.next == .month)
        #expect(JournalZoom.month.next == .year)
        #expect(JournalZoom.year.next == .list)
    }

    @Test("fingers together zoom out, apart zoom in, never past either end")
    func pinch() {
        #expect(JournalZoom.list.pinched(0.5) == .month)
        #expect(JournalZoom.month.pinched(0.5) == .year)
        #expect(JournalZoom.year.pinched(0.5) == nil)
        #expect(JournalZoom.year.pinched(1.6) == .month)
        #expect(JournalZoom.month.pinched(1.6) == .list)
        #expect(JournalZoom.list.pinched(1.6) == nil)
    }

    @Test("a small pinch is not a zoom")
    func smallPinch() {
        for zoom in [JournalZoom.list, .month, .year] {
            #expect(zoom.pinched(0.95) == nil)
            #expect(zoom.pinched(1.1) == nil)
        }
    }

    @Test("the list has no calendar level; month and year keep their telemetry names")
    func levels() {
        #expect(JournalZoom.list.calendarLevel == nil)
        #expect(JournalZoom.month.calendarLevel == .month)
        #expect(JournalZoom.year.calendarLevel == .year)
    }

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
