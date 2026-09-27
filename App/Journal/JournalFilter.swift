import AteKit
import SwiftUI

// MARK: - The sheet

/// **The Journal's filter sheet** — the design system's one filter sheet (``AteFilterSheet``) with
/// the Journal's sections: the order as a three-way segment, then rating, diet, when, and the places
/// you have written at as radio rows. Nothing is applied until Done.
struct JournalFilterSheet: View {
    let places: [JournalPlace]
    /// Whether ``places`` has answered — until it has, the section is still rows (round 5).
    var arePlacesLoaded = true
    let periods: [JournalPeriod]
    let onDone: (JournalQuery) -> Void

    @State private var query: JournalQuery

    init(
        initial: JournalQuery,
        places: [JournalPlace],
        arePlacesLoaded: Bool = true,
        periods: [JournalPeriod],
        onDone: @escaping (JournalQuery) -> Void
    ) {
        self.places = places
        self.arePlacesLoaded = arePlacesLoaded
        self.periods = periods
        self.onDone = onDone
        _query = State(initialValue: initial)
    }

    var body: some View {
        AteFilterSheet(isLoading: arePlacesLoaded == false) {
            AteSegments(
                options: JournalSort.allCases.map { AteSegment($0, $0.title) },
                selection: $query.sort
            )
            AteFilterSection(title: "Rating") {
                AteFilterChoice(title: "Any", isOn: query.minScore == nil) { query.minScore = nil }
                ForEach(JournalQuery.minScoreSteps, id: \.self) { step in
                    AteFilterChoice(title: ScoreFormat.halfStep(step) + "+", isOn: query.minScore == step) {
                        query.minScore = step
                    }
                }
            }
            AteFilterSection(title: "Diet") {
                AteFilterChoice(title: "Any", isOn: query.tag == nil) { query.tag = nil }
                ForEach(DietTag.allCases, id: \.self) { tag in
                    AteFilterChoice(title: tag.label, isOn: query.tag == tag, accessibilityName: tag.spokenName) {
                        query.tag = tag
                    }
                }
            }
            AteFilterSection(title: "When") {
                AteFilterChoice(title: "Any time", isOn: query.period == nil) { query.period = nil }
                ForEach(periods, id: \.self) { period in
                    AteFilterChoice(title: period.title(), isOn: query.period == period) { query.period = period }
                }
            }
            AteFilterSection(title: "Place", scrolls: false) {
                AteRadioRow(title: "Anywhere", isSelected: query.place == nil) { query.place = nil }
                if arePlacesLoaded == false { AteSheetSkeletonRows(count: 4) }
                ForEach(places) { place in
                    AteRadioRow(
                        title: place.name,
                        subtitle: place.locality,
                        isSelected: query.place?.id == place.id
                    ) {
                        query.place = place
                    }
                }
            }
        } onDone: {
            onDone(query)
        }
    }
}

extension JournalQuery {
    /// The active filters as the row under the control draws them.
    var activeFilters: [AteActiveFilter] {
        pills.map { AteActiveFilter(id: $0.id, title: $0.title) }
    }

    /// The query without the pill the reader took away.
    func removing(_ filter: AteActiveFilter) -> JournalQuery {
        guard let pill = pills.first(where: { $0.id == filter.id }) else { return self }
        return removing(pill)
    }
}

// MARK: - Month markers

/// **A quiet month marker** — while the journal scrolls, the month of the entries at the top of the
/// screen, small, on glass, at the top; gone a moment after the list comes to rest. Only when the
/// list runs through time.
struct JournalMonthMarker: View {
    let title: String

    var body: some View {
        Text(title)
            .ateText(.meta)
            .foregroundStyle(AtePalette.automatic.fg)
            .padding(.horizontal, 12)
            .frame(height: 28)
            .ateGlass(in: Capsule()) // the chrome's glass (round 5), not the system's
            .accessibilityHidden(true)
    }
}

// MARK: - Periods on offer

enum JournalPeriods {
    /// What the "When" filter offers: the last twelve months, newest first, then each earlier year
    /// back to the oldest entry on hand (at least last year).
    static func offered(
        now: Date = Date(),
        oldest: Date?,
        calendar: Calendar = .autoupdatingCurrent
    ) -> [JournalPeriod] {
        var periods: [JournalPeriod] = []
        for back in 0..<12 {
            guard let date = calendar.date(byAdding: .month, value: -back, to: now) else { continue }
            periods.append(JournalPeriod.month(of: date, calendar: calendar))
        }
        let thisYear = calendar.component(.year, from: now)
        let firstYear = min(thisYear - 1, oldest.map { calendar.component(.year, from: $0) } ?? thisYear - 1)
        for year in stride(from: thisYear, through: firstYear, by: -1) {
            periods.append(.year(year))
        }
        return periods
    }
}
