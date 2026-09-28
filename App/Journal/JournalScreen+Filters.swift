import AteKit
import SwiftUI

/// The Journal's chips and its calendar: what is on, opening and clearing a chip, applying a sheet,
/// and zooming out to the calendar and back in to a day.
extension JournalScreen {

    // MARK: - The filters, shared by the shelves

    /// What the chips show: the Journal's query (the range, the city and the months are Saved's too;
    /// the order is the Journal's alone).
    var filters: BrowseFilters { BrowseFilters(store.query) }

    var chips: [BrowseChip] { BrowseChip.chips(on: shelf == .journal ? .journal : .saved) }

    private var surface: BrowseEvents.FilterSurface { shelf == .journal ? .journal : .saved }

    /// The city chip's name, as the shelf's own list spells it.
    var cityName: String? {
        guard let city = filters.city else { return nil }
        return AteCity.displayName(for: city, in: shelf == .journal ? store.cities : saved.cities)
    }

    func open(_ chip: BrowseChip) {
        AteTelemetry.record(BrowseEvents.chipOpened(chip, on: surface))
        openChip = chip
    }

    func clear(_ chip: BrowseChip) {
        AteTelemetry.record(BrowseEvents.chipCleared(chip, on: surface))
        apply(filters.clearing(chip))
    }

    /// What a City sheet waits on before it rises: the shelf's own cities, if they have not answered.
    func loadCitiesIfNeeded() async {
        switch shelf {
        case .journal: await store.loadCitiesIfNeeded()
        case .saved: await saved.loadCitiesIfNeeded()
        }
    }

    func chipSheet(_ chip: BrowseChip) -> some View {
        let isJournal = shelf == .journal
        let store = store
        let saved = saved
        return JournalChipSheet(
            chip: chip,
            shelf: isJournal ? .journal : .saved,
            initial: filters,
            // Each shelf offers the cities it holds: you can save a dish in a city you have never
            // written in.
            cities: isJournal ? store.cities : saved.cities,
            areCitiesLoaded: isJournal ? store.hasLoadedCities : saved.hasLoadedCities,
            count: { draft in
                isJournal
                    ? try await store.count(draft.journalQuery)
                    : try await saved.count(draft.savedFilter)
            },
            onShow: { apply($0) }
        )
    }

    /// One sheet's Show, or a chip cleared: the Journal's query, and the same range, city and months
    /// on the Saved shelf. Only a shelf whose list changes is read again.
    func apply(_ next: BrowseFilters) {
        let query = next.journalQuery
        let shelfFilter = next.savedFilter
        guard query != store.query || shelfFilter != saved.filter else { return }
        listChanged += 1
        // Two reads, side by side: neither shelf waits on the other.
        Task { await applyJournal(query) }
        Task { await applyShelf(shelfFilter) }
    }

    private func applyJournal(_ query: JournalQuery) async {
        guard query != store.query else { return }
        await store.apply(query)
        AteTelemetry.record(BrowseEvents.journalQueried(query, resultCount: store.entries.count))
    }

    private func applyShelf(_ filter: SavedDishFilter) async {
        guard filter != saved.filter else { return }
        await saved.apply(filter)
        AteTelemetry.record(BrowseEvents.savedFiltered(filter, resultCount: saved.dishes.count))
    }

    /// A drive's starting state: Rating 4.0 and up (`RatingChip`), and its sheet already open over it.
    func openDebugState() async {
        #if DEBUG
        if JournalDebugLaunch.startsFiltered {
            apply(BrowseFilters(band: ScoreBand.Preset.fourPlus.band))
        }
        guard JournalDebugLaunch.opensFilter else { return }
        // Once the demo filter has landed, so the sheet opens on it.
        try? await Task.sleep(for: .seconds(2))
        openChip = .rating
        #endif
    }

    // MARK: - The calendar

    /// Zoom out to the month the list is in (the header's button, or fingers together on the list).
    func openCalendar(via way: BrowseEvents.CalendarWay) {
        calendarMonth = (shelf == .journal ? topMonth : nil) ?? AteMonth.containing(Date())
        AteTelemetry.record(BrowseEvents.calendarOpened(.month, via: way))
        calendarLevel = .month
    }

    func calendar(proxy: ScrollViewProxy) -> some View {
        JournalCalendarView(
            store: store.calendarDays,
            level: Binding(get: { calendarLevel ?? .month }, set: { calendarLevel = $0 }),
            month: $calendarMonth,
            onBack: { calendarLevel = nil },
            onDay: { day in openDay(day, proxy: proxy) },
            onLevel: { level, way in
                AteTelemetry.record(BrowseEvents.calendarOpened(level, via: way))
                calendarLevel = level
            }
        )
    }

    /// A day tapped: the Journal, read on until the day is in it, and the list back — at that day.
    /// A list ordered by score has no days, so it goes back to newest first, its filters kept.
    private func openDay(_ day: AteDay, proxy: ScrollViewProxy) {
        if shelf != .journal { shelf = .journal }
        Task {
            if store.query.sort.isChronological == false {
                var next = filters
                next.sort = .newest
                listChanged += 1
                await store.apply(next.journalQuery)
            }
            let landing = await store.reveal(day)
            if let landing {
                let dividers = JournalMonthDividers.dividers(for: store.entries, sort: store.query.sort)
                let target = dividers[landing.id] != nil ? Self.dividerID(landing.id) : Self.gapID(landing.id)
                var jump = Transaction(animation: nil)
                jump.disablesAnimations = true
                withTransaction(jump) { proxy.scrollTo(target, anchor: .top) }
            }
            let exact = landing.map { AteDay.containing($0.createdAt) == day } ?? false
            AteTelemetry.record(BrowseEvents.calendarDayOpened(exact: exact))
            calendarLevel = nil
        }
    }
}
