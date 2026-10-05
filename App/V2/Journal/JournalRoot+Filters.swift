import AteKit
import SwiftUI

/// The Journal's filters: what is on, the chips under the bar, and the one sheet.
extension JournalRoot {

    /// What is on: the Journal's query.
    var filters: BrowseFilters { BrowseFilters(journal.query) }

    /// The city's name, as the Journal's own list spells it.
    var cityName: String? {
        guard let city = filters.city else { return nil }
        return AteCity.displayName(for: city, in: journal.cities)
    }

    // MARK: - The chips

    /// Under the bar, only while a filter is on: each chip its value and an ✕. No row otherwise.
    @ViewBuilder
    var activeChips: some View {
        let active = filters.activeChips(on: .journal)
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
        app.services.analytics(BrowseEvents.chipCleared(chip, on: .journal))
        apply(filters.clearing(chip))
    }

    // MARK: - The sheet

    func openFilter() {
        app.services.analytics(BrowseEvents.filterOpened(on: .journal))
        isFiltering = true
    }

    var filterSheet: some View {
        let journal = journal
        return JournalFilterSheet(
            shelf: .journal,
            initial: filters,
            cities: journal.cities,
            count: { draft in try await journal.count(draft.journalQuery) },
            onShow: { apply($0) }
        )
        .task { await journal.loadCitiesIfNeeded() }
    }

    /// The sheet's Show, or a chip cleared: the Journal read again for the new query.
    func apply(_ next: BrowseFilters) {
        let query = next.journalQuery
        guard query != journal.query else { return }
        listChanged += 1
        Task {
            await journal.apply(query)
            app.services.analytics(BrowseEvents.journalQueried(query, resultCount: journal.entries.count))
        }
    }
}
