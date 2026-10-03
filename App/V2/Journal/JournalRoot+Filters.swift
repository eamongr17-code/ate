import AteKit
import SwiftUI

/// The Journal's filters: what is on, the chips under the bar, the one sheet, and applying it to
/// both shelves.
extension JournalRoot {

    /// What is on: the Journal's query (the range, the city and the months are Saved's too; the
    /// order is the Journal's alone).
    var filters: BrowseFilters { BrowseFilters(journal.query) }

    var chipShelf: BrowseChip.Shelf { shelf == .journal ? .journal : .saved }

    var surface: BrowseEvents.FilterSurface { shelf == .journal ? .journal : .saved }

    /// The city's name, as the shelf's own list spells it.
    var cityName: String? {
        guard let city = filters.city else { return nil }
        return AteCity.displayName(for: city, in: shelf == .journal ? journal.cities : saved.cities)
    }

    // MARK: - The chips

    /// Under the bar, only while a filter is on: each chip its value and an ✕. No row otherwise,
    /// and none while the page is zoomed out.
    @ViewBuilder
    var activeChips: some View {
        let active = zoom == .list ? filters.activeChips(on: chipShelf) : []
        if active.isEmpty == false {
            AteFilterChipRow(
                chips: active.map { chip in
                    AteFilterChipRow.Chip(
                        id: chip.rawValue,
                        title: filters.title(of: chip, cityName: chip == .city ? cityName : nil)
                    )
                },
                onOpen: { openFilter() },
                onClear: { chip in
                    guard let chip = BrowseChip(rawValue: chip.id) else { return }
                    clear(chip)
                }
            )
            .padding(.vertical, AteMetrics.snug)
        }
    }

    func clear(_ chip: BrowseChip) {
        app.services.analytics(BrowseEvents.chipCleared(chip, on: surface))
        apply(filters.clearing(chip))
    }

    // MARK: - The sheet

    func openFilter() {
        app.services.analytics(BrowseEvents.filterOpened(on: surface))
        isFiltering = true
    }

    var filterSheet: some View {
        let isJournal = shelf == .journal
        let journal = journal
        let saved = saved
        return JournalFilterSheet(
            shelf: chipShelf,
            initial: filters,
            // Each shelf offers the cities it holds: a dish can be saved in a city you have never
            // written in.
            cities: isJournal ? journal.cities : saved.cities,
            count: { draft in
                isJournal
                    ? try await journal.count(draft.journalQuery)
                    : try await saved.count(draft.savedFilter)
            },
            onShow: { apply($0) }
        )
        .task {
            if isJournal { await journal.loadCitiesIfNeeded() } else { await saved.loadCitiesIfNeeded() }
        }
    }

    /// The sheet's Show, or a chip cleared: the Journal's query, and the same range, city and months
    /// on the Saved shelf. Only a shelf whose list changes is read again.
    func apply(_ next: BrowseFilters) {
        let query = next.journalQuery
        let shelfFilter = next.savedFilter
        guard query != journal.query || shelfFilter != saved.filter else { return }
        listChanged += 1
        // Two reads, side by side: neither shelf waits on the other.
        Task { await applyJournal(query) }
        Task { await applyShelf(shelfFilter) }
    }

    private func applyJournal(_ query: JournalQuery) async {
        guard query != journal.query else { return }
        await journal.apply(query)
        app.services.analytics(BrowseEvents.journalQueried(query, resultCount: journal.entries.count))
    }

    private func applyShelf(_ filter: SavedDishFilter) async {
        guard filter != saved.filter else { return }
        await saved.apply(filter)
        app.services.analytics(BrowseEvents.savedFiltered(filter, resultCount: saved.dishes.count))
    }
}
