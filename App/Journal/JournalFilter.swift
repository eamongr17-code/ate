import AteKit
import SwiftUI

// MARK: - The pill

/// **A filter pill** — the one control both entry points are made of. A 36pt pill: on the field
/// colour when it is a question (B's "Place"), ink when it carries an answer ("Tipo 00"), and an
/// answer can always be taken away with its ✕. Pills are the app's shape for a control (rule 3).
struct JournalFilterPill: View {
    let title: String
    var isOn = false
    /// B's pills open a menu; the chevron says so. A's removable pills have none.
    var opensMenu = false
    var onRemove: (() -> Void)?

    @Environment(\.atePalette) private var palette

    static let height: CGFloat = 36

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
                .ateText(.controlSmall)
                .lineLimit(1)
            if opensMenu, isOn == false {
                AteIcon.chevron.view(size: 12)
                    .rotationEffect(.degrees(90))
                    .accessibilityHidden(true)
            }
            if let onRemove {
                Button(action: onRemove) {
                    AteIcon.close.view(size: 12)
                        .frame(width: 24, height: 24)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .padding(.trailing, -6)
                .accessibilityLabel("Remove \(title)")
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, onRemove == nil ? 14 : 10)
        .frame(height: Self.height)
        .background(isOn ? palette.fg : palette.chip, in: .capsule)
        .foregroundStyle(isOn ? palette.inverted : palette.fg)
        .fixedSize()
    }
}

/// The active filters, as removable pills in a row that scrolls sideways — variant A shows these
/// under the segment; B's own row *is* this, with the unset questions after the answers.
struct JournalActivePills: View {
    let query: JournalQuery
    let onChange: (JournalQuery) -> Void

    var body: some View {
        ForEach(query.pills) { pill in
            JournalFilterPill(title: pill.title, isOn: true) {
                onChange(query.removing(pill))
            }
            .accessibilityIdentifier("journal.filter.pill.\(pill.id)")
        }
    }
}

// MARK: - A: the control and its sheet

/// **A** — a small control beside the Journal | Saved segment: the filter mark in a chip-coloured
/// disc, ink when anything is set. It opens ``JournalFilterSheet``.
struct JournalFilterButton: View {
    let isActive: Bool
    let action: () -> Void

    @Environment(\.atePalette) private var palette

    var body: some View {
        Button(action: action) {
            AteIcon.filter.view(size: 20)
                .frame(width: AteMetrics.hit, height: AteMetrics.hit)
                .background(isActive ? palette.fg : palette.chip, in: .circle)
                .foregroundStyle(isActive ? palette.inverted : palette.fg)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Filter")
        .accessibilityValue(isActive ? "On" : "Off")
        .accessibilityIdentifier("journal.filter")
    }
}

/// **A's sheet** — the order as a three-way segment, then rating, diet, when and place as pills
/// and radio rows. Nothing is applied until Done: the list behind it re-reads once, not per tap.
struct JournalFilterSheet: View {
    let initial: JournalQuery
    let places: [JournalPlace]
    let periods: [JournalPeriod]
    let onDone: (JournalQuery) -> Void

    @State private var query: JournalQuery
    @Environment(\.dismiss) private var dismiss

    init(
        initial: JournalQuery,
        places: [JournalPlace],
        periods: [JournalPeriod],
        onDone: @escaping (JournalQuery) -> Void
    ) {
        self.initial = initial
        self.places = places
        self.periods = periods
        self.onDone = onDone
        _query = State(initialValue: initial)
    }

    var body: some View {
        AteSheet(title: "Filter", primary: ("Done", {
            onDone(query)
            dismiss()
        })) {
            VStack(alignment: .leading, spacing: AteMetrics.section) {
                AteSegments(
                    options: JournalSort.allCases.map { AteSegment($0, $0.title) },
                    selection: $query.sort
                )
                section("Rating") {
                    choice("Any", isOn: query.minScore == nil) { query.minScore = nil }
                    ForEach(JournalQuery.minScoreSteps, id: \.self) { step in
                        choice(ScoreFormat.halfStep(step) + "+", isOn: query.minScore == step) { query.minScore = step }
                    }
                }
                section("Diet") {
                    choice("Any", isOn: query.tag == nil) { query.tag = nil }
                    ForEach(DietTag.allCases, id: \.self) { tag in
                        choice(tag.label, isOn: query.tag == tag) { query.tag = tag }
                            .accessibilityLabel(tag.spokenName)
                    }
                }
                section("When") {
                    choice("Any time", isOn: query.period == nil) { query.period = nil }
                    ForEach(periods, id: \.self) { period in
                        choice(period.title(), isOn: query.period == period) { query.period = period }
                    }
                }
                VStack(alignment: .leading, spacing: 0) {
                    label("Place")
                    AteRadioRow(title: "Anywhere", isSelected: query.place == nil) { query.place = nil }
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
            }
            .padding(.top, AteMetrics.tight)
            .padding(.bottom, AteMetrics.loose)
        }
        .presentationDetents([.large])
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .ateText(.meta)
            .foregroundStyle(AtePalette.surface.muted)
            .padding(.bottom, AteMetrics.snug)
    }

    private func section(_ title: String, @ViewBuilder _ pills: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            label(title)
            ScrollView(.horizontal) {
                HStack(spacing: AteMetrics.snug) { pills() }
            }
            .scrollIndicators(.hidden)
        }
    }

    private func choice(_ title: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            JournalFilterPill(title: title, isOn: isOn)
                .environment(\.atePalette, isOn ? .surface : Self.onSurface)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
    }

    /// On the sheet's white, an unset pill is the field colour — a chip would vanish into it.
    private static var onSurface: AtePalette {
        var palette = AtePalette.surface
        palette.chip = palette.field
        return palette
    }
}

// MARK: - B: the pill row

/// **B** — a pill row under the segment that scrolls sideways: the order first, then one pill per
/// filter. An unset filter is a question that opens the system's own menu; a set one is ink,
/// carries its answer, and its ✕ takes it off.
struct JournalFilterRow: View {
    let query: JournalQuery
    let places: [JournalPlace]
    let periods: [JournalPeriod]
    let onChange: (JournalQuery) -> Void
    let onOpen: () -> Void

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: AteMetrics.snug) {
                sortMenu
                filterMenu(title: "Place", pill: query.place.map(JournalQueryPill.place)) {
                    ForEach(places) { place in
                        Button(place.name) { set { $0.place = place } }
                    }
                }
                filterMenu(title: "Rating", pill: query.minScore.map(JournalQueryPill.minScore)) {
                    ForEach(JournalQuery.minScoreSteps, id: \.self) { step in
                        Button(ScoreFormat.halfStep(step) + "+") { set { $0.minScore = step } }
                    }
                }
                filterMenu(title: "Diet", pill: query.tag.map(JournalQueryPill.tag)) {
                    ForEach(DietTag.allCases, id: \.self) { tag in
                        Button(tag.label) { set { $0.tag = tag } }
                    }
                }
                filterMenu(title: "When", pill: query.period.map(JournalQueryPill.period)) {
                    ForEach(periods, id: \.self) { period in
                        Button(period.title()) { set { $0.period = period } }
                    }
                }
            }
            .padding(.horizontal, AteMetrics.listGutter)
        }
        .scrollIndicators(.hidden)
        .accessibilityIdentifier("journal.filterRow")
    }

    private func set(_ change: (inout JournalQuery) -> Void) {
        var next = query
        change(&next)
        onChange(next)
    }

    /// The order: always an answer, ink only when it is not the default.
    private var sortMenu: some View {
        Menu {
            Picker("Sort", selection: Binding(get: { query.sort }, set: { sort in set { $0.sort = sort } })) {
                ForEach(JournalSort.allCases, id: \.self) { Text($0.title).tag($0) }
            }
        } label: {
            JournalFilterPill(title: query.sort.title, isOn: query.sort != .newest, opensMenu: true)
        }
        .simultaneousGesture(TapGesture().onEnded(onOpen))
        .accessibilityIdentifier("journal.filter.sort")
    }

    @ViewBuilder
    private func filterMenu(
        title: String,
        pill: JournalQueryPill?,
        @ViewBuilder items: () -> some View
    ) -> some View {
        if let pill {
            JournalFilterPill(title: pill.title, isOn: true) {
                onChange(query.removing(pill))
            }
            .accessibilityIdentifier("journal.filter.pill.\(pill.id)")
        } else {
            Menu {
                items()
            } label: {
                JournalFilterPill(title: title, opensMenu: true)
            }
            .simultaneousGesture(TapGesture().onEnded(onOpen))
            .accessibilityIdentifier("journal.filter.\(title.lowercased())")
        }
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
            .glassEffect(.regular, in: .capsule)
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
