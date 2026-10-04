import AteKit
import SwiftUI

/// **The Journal zoomed out** — a month, or the year, under the same bar.
///
/// The months are one vertical list, oldest at the top and this month at the foot, like the system
/// Calendar's (build 87: "a scroll up and down, not a sideways scroll"); the years are one too.
/// The month: days you wrote are photo tiles, a 5.0 day ringed in butter and a 6 in brick; a day you
/// wrote with no photo is its numeral over an ink dot; today, unwritten, is its numeral on an ink
/// disc. Each month's year, beside its name, opens the years; a month tapped there opens the months
/// at it. The year: twelve small months of dots, the 5.0 days in butter and the 6s in brick, larger.
/// No legend, no back control: the calendar control closes either level back to the list.
///
/// Both lists are plain (not lazy) stacks, so every month's place is known before the first frame
/// and each opens exactly where it is asked to (build 88: a lazy stack's estimates opened it on
/// January).
struct JournalZoomView: View {
    let store: JournalCalendarStore
    let zoom: JournalZoom
    @Binding var month: AteMonth
    var now = Date()
    let onDay: (AteDay) -> Void
    let onYear: () -> Void
    let onMonth: (AteMonth) -> Void

    /// The list waits for the first year to be known: months added above it after it opened would
    /// push the opening month off the screen. (The Journal reads it ahead, so this is rarely seen.)
    @State private var isReady = false

    var body: some View {
        ZStack {
            if isReady {
                switch zoom {
                case .year:
                    JournalZoomYears(store: store, month: $month, now: now, onMonth: onMonth)
                        .transition(.asymmetric(insertion: .opacity, removal: .identity))
                default:
                    JournalZoomMonths(store: store, month: $month, now: now, onDay: onDay, onYear: onYear)
                        .transition(.asymmetric(insertion: .opacity, removal: .identity))
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .task {
            await store.loadFirstYear()
            isReady = true
        }
        .task(id: month.year) { await store.loadYear(month.year) }
    }
}

/// Where a calendar list opens: with the page asked for at the top (the last pages clamp at the
/// foot), by the reader's own scroll (a `ScrollPosition` landed a fixed distance short). The plain
/// stack's every page has its exact place and a height that never changes as its year loads, so
/// the list is held on that page through every layout pass (the safe area and the content settling
/// as it appears) until you first touch it — no timers, no estimates.
private struct JournalZoomOpening<ID: Hashable & Sendable>: ViewModifier {
    let id: ID
    let proxy: ScrollViewProxy
    @State private var isHeld = true

    func body(content: Content) -> some View {
        content
            .onScrollGeometryChange(for: JournalZoomLayout.self) { geometry in
                JournalZoomLayout(
                    content: geometry.contentSize.height,
                    container: geometry.containerSize.height,
                    inset: geometry.contentInsets.top
                )
            } action: { _, _ in
                if isHeld { proxy.scrollTo(id, anchor: .top) }
            }
            .onScrollPhaseChange { _, phase in
                if phase == .interacting { isHeld = false }
            }
            .onAppear { proxy.scrollTo(id, anchor: .top) }
    }
}

private struct JournalZoomLayout: Equatable {
    let content: CGFloat
    let container: CGFloat
    let inset: CGFloat
}

// MARK: - The months

/// Every month from the first year you wrote in to this one, top to bottom, opening on the month
/// asked for.
private struct JournalZoomMonths: View {
    let store: JournalCalendarStore
    @Binding var month: AteMonth
    let now: Date
    let onDay: (AteDay) -> Void
    let onYear: () -> Void

    /// The month it opened on, fixed for the life of the list.
    @State private var opening: AteMonth
    @State private var hasScrolled = false

    init(
        store: JournalCalendarStore,
        month: Binding<AteMonth>,
        now: Date,
        onDay: @escaping (AteDay) -> Void,
        onYear: @escaping () -> Void
    ) {
        self.store = store
        self._month = month
        self.now = now
        self.onDay = onDay
        self.onYear = onYear
        self._opening = State(initialValue: min(month.wrappedValue, AteMonth.containing(now)))
    }

    private var current: AteMonth { AteMonth.containing(now) }

    private var range: [AteMonth] {
        let firstYear = min(store.firstYear ?? current.year, month.year)
        let first = AteMonth(year: firstYear, month: 1)
        return (0...max(first.distance(to: current), 0)).map { first.adding(months: $0) }
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: JournalMetrics.monthGap) {
                    ForEach(range, id: \.self) { page in
                        // Each month carries its own inset, so a jump to it never scrolls sideways.
                        JournalZoomMonth(month: page, store: store, now: now, onDay: onDay, onYear: onYear)
                            .padding(.horizontal, AteMetrics.loose)
                            .task { await store.loadYear(page.year) }
                    }
                }
                .scrollTargetLayout()
                .padding(.bottom, AteMetrics.loose)
            }
            .modifier(JournalZoomOpening(id: opening, proxy: proxy))
            .onScrollPhaseChange { _, phase in
                if phase == .interacting { hasScrolled = true }
            }
            .onScrollTargetVisibilityChange(
                idType: AteMonth.self, threshold: JournalZoomMetrics.visibleShare
            ) { shown in
                // Only a scroll of yours moves the month: where it opened must not read as a choice.
                guard hasScrolled, let top = shown.min(), top != month else { return }
                month = top
            }
            .accessibilityIdentifier("journal.calendar.months")
        }
    }
}

// MARK: - The years

/// Every year from the first you wrote in to this one, top to bottom, opening on the year asked for.
private struct JournalZoomYears: View {
    let store: JournalCalendarStore
    @Binding var month: AteMonth
    let now: Date
    let onMonth: (AteMonth) -> Void

    @State private var opening: Int

    init(store: JournalCalendarStore, month: Binding<AteMonth>, now: Date, onMonth: @escaping (AteMonth) -> Void) {
        self.store = store
        self._month = month
        self.now = now
        self.onMonth = onMonth
        self._opening = State(initialValue: min(month.wrappedValue.year, AteMonth.containing(now).year))
    }

    private var current: AteMonth { AteMonth.containing(now) }

    private var range: [Int] {
        Array(min(store.firstYear ?? current.year, month.year)...current.year)
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: JournalMetrics.monthGap) {
                    ForEach(range, id: \.self) { year in
                        JournalZoomYear(year: year, store: store, now: now, onMonth: onMonth)
                            .padding(.horizontal, AteMetrics.loose)
                            .task { await store.loadYear(year) }
                    }
                }
                .scrollTargetLayout()
                .padding(.bottom, AteMetrics.loose)
            }
            .modifier(JournalZoomOpening(id: opening, proxy: proxy))
            .accessibilityIdentifier("journal.calendar.years")
        }
    }
}

private enum JournalZoomMetrics {
    /// How much of a month must be on screen to count as the one you are looking at.
    static let visibleShare = 0.5
    /// What holds an empty summary's line open (never shown).
    static let placeholder = "0 visits"
}

/// A zoomed-out page's title: the month (or the year) large, its year muted beside it when it is
/// not this one (as the month divider sets it), and what it adds up to at the end.
private struct JournalZoomTitle: View {
    let title: String
    var year: String?
    var trailing: [String] = []
    /// A month's year, trailing, as a quiet button to the years.
    var onYear: (() -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: AteMonthDividerMetrics.gap) {
            Text(title)
                .ateTextLine(.monthTitle)
                .foregroundStyle(AtePalette.automatic.fg)
                .lineLimit(1)
            if let year, onYear == nil {
                AteMetaParts(parts: [year])
            }
            Spacer(minLength: 0)
            if trailing.isEmpty == false {
                AteMetaParts(parts: trailing)
            }
            if let onYear, let year {
                yearButton(year, action: onYear)
            }
        }
        .padding(.horizontal, AteMetrics.tight)
        .padding(.top, AteMetrics.loose)
        .accessibilityElement(children: onYear == nil ? .combine : .contain)
        .accessibilityAddTraits(onYear == nil ? .isHeader : [])
    }

    private func yearButton(_ year: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: AteMetrics.hairspace) {
                Text(year)
                    .ateText(.meta)
                    .monospacedDigit()
                AteIcon.chevron.view(size: JournalShelfMetrics.chevron)
            }
            .foregroundStyle(AtePalette.automatic.muted)
            // A full target without growing the title's row.
            .padding(AteMetrics.regular)
            .contentShape(.rect)
            .padding(-AteMetrics.regular)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(year), all months")
        .accessibilityIdentifier("calendar.year.\(year)")
    }
}

// MARK: - A month

private struct JournalZoomMonth: View {
    let month: AteMonth
    let store: JournalCalendarStore
    let now: Date
    let onDay: (AteDay) -> Void
    let onYear: () -> Void

    private let columns = Array(
        repeating: GridItem(.flexible(minimum: 0), spacing: JournalMetrics.cellGap),
        count: JournalCalendar.weekdayCount
    )

    var body: some View {
        VStack(alignment: .leading, spacing: AteMetrics.loose) {
            JournalZoomTitle(title: month.name(), year: String(month.year), onYear: onYear)
            LazyVGrid(columns: columns, spacing: JournalMetrics.cellGap) {
                ForEach(Array(JournalCalendar.weekdayInitials().enumerated()), id: \.offset) { _, initial in
                    Text(initial)
                        .ateText(.calendarWeekday)
                        .foregroundStyle(AtePalette.automatic.muted)
                        .accessibilityHidden(true)
                }
            }
            LazyVGrid(columns: columns, spacing: JournalMetrics.cellGap) {
                ForEach(Array(JournalCalendar.grid(for: month).enumerated()), id: \.offset) { _, day in
                    if let day {
                        JournalZoomDay(
                            day: day,
                            count: store.day(day),
                            isToday: day == AteDay.containing(now),
                            onTap: { onDay(day) }
                        )
                    } else {
                        Color.clear.aspectRatio(1, contentMode: .fit)
                    }
                }
            }
            // The summary's line is always there, held empty until the month has visits: a month
            // never grows as its year loads, so the month the list opened on stays put.
            let summary = store.summary(of: month)
            AteMetaParts(parts: summary.visits > 0 ? summary.parts : [JournalZoomMetrics.placeholder])
                .opacity(summary.visits > 0 ? 1 : 0)
                .accessibilityHidden(summary.visits == 0)
                .padding(.horizontal, AteMetrics.tight)
        }
    }
}

/// One day's square.
private struct JournalZoomDay: View {
    let day: AteDay
    let count: JournalDayCount?
    let isToday: Bool
    let onTap: () -> Void

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: JournalMetrics.tileCorner, style: .continuous)
    }

    var body: some View {
        if let count {
            Button(action: onTap) { written(count) }
                .buttonStyle(.plain)
                .accessibilityLabel(accessibilityLabel(count))
                .accessibilityIdentifier("calendar.day.\(day.string)")
        } else {
            Color.clear
                .aspectRatio(1, contentMode: .fit)
                .overlay { unwritten }
                .accessibilityHidden(true)
        }
    }

    /// A day with nothing written: its numeral, muted — or today's, on the ink disc.
    @ViewBuilder
    private var unwritten: some View {
        if isToday {
            Text(String(day.day))
                .ateText(.calendarDay)
                .foregroundStyle(AtePalette.automatic.inverted)
                .frame(width: JournalMetrics.today, height: JournalMetrics.today)
                .background(AtePalette.automatic.solid, in: .circle)
        } else {
            Text(String(day.day))
                .ateText(.calendarDay)
                .foregroundStyle(AtePalette.automatic.muted)
                .fixedSize()
        }
    }

    private func written(_ count: JournalDayCount) -> some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let cover = count.coverURL {
                    AtePhotoContent(photo: .remote(cover), size: .forSide(AteThumbMetrics(.row).height))
                } else {
                    // Written, with no photo: the numeral in ink, and a dot under it.
                    Text(String(day.day))
                        .ateText(.calendarDay)
                        .foregroundStyle(AtePalette.automatic.fg)
                        .fixedSize()
                        .overlay(alignment: .bottom) {
                            Circle()
                                .fill(AtePalette.automatic.fg)
                                .frame(width: JournalMetrics.dot, height: JournalMetrics.dot)
                                .alignmentGuide(.bottom) { $0[.top] - JournalMetrics.dotBottom }
                        }
                }
            }
            // The numeral sits on the tile, not on the photo: a photo filling the square overhangs it,
            // and a numeral pinned to the photo's corner was cut off at the tile's edge ("19" as "9").
            .overlay(alignment: .bottomLeading) {
                if count.coverURL != nil {
                    Text(String(day.day))
                        .ateText(.calendarDayOnPhoto)
                        .foregroundStyle(AteCalendarColor.overPhoto)
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.leading, JournalMetrics.numeralInset)
                        .padding(.bottom, JournalMetrics.numeralBottom)
                }
            }
            .clipShape(shape)
            .overlay {
                if let ring = ringColour(count.mark) {
                    shape.strokeBorder(ring, lineWidth: JournalMetrics.ring)
                        .padding(-JournalMetrics.ring)
                }
            }
            .contentShape(shape)
    }

    private func ringColour(_ mark: JournalDayMark) -> Color? {
        switch mark {
        case .five: AteCalendarColor.five
        case .six: AteCalendarColor.six
        case .visit: nil
        }
    }

    private func accessibilityLabel(_ count: JournalDayCount) -> String {
        let date = day.start().formatted(.dateTime.weekday(.wide).day().month(.wide))
        let entries = count.entries == 1 ? "1 entry" : "\(count.entries) entries"
        switch count.mark {
        case .five: return "\(date), \(entries), a 5.0"
        case .six: return "\(date), \(entries), a 6"
        case .visit: return "\(date), \(entries)"
        }
    }
}

// MARK: - A year

private struct JournalZoomYear: View {
    let year: Int
    let store: JournalCalendarStore
    let now: Date
    let onMonth: (AteMonth) -> Void

    private let columns = Array(
        repeating: GridItem(.flexible(minimum: 0), spacing: JournalMetrics.yearColumnGap, alignment: .topLeading),
        count: JournalMetrics.yearColumns
    )

    var body: some View {
        VStack(alignment: .leading, spacing: AteMetrics.loose) {
            let summary = store.summary(ofYear: year)
            JournalZoomTitle(title: String(year), trailing: summary.visits > 0 ? summary.parts : [])
            LazyVGrid(columns: columns, alignment: .leading, spacing: JournalMetrics.yearRowGap) {
                ForEach(1...12, id: \.self) { index in
                    let month = AteMonth(year: year, month: index)
                    Button { onMonth(month) } label: { mini(month) }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(month.name()) \(String(year))")
                        .accessibilityIdentifier("calendar.month.\(index)")
                }
            }
        }
    }

    private func mini(_ month: AteMonth) -> some View {
        let isPast = month <= AteMonth.containing(now)
        return VStack(alignment: .leading, spacing: AteMetrics.tight) {
            Text(month.shortName())
                .ateText(.calendarMiniMonth)
                .foregroundStyle(isPast ? AtePalette.automatic.fg : AtePalette.automatic.muted)
            LazyVGrid(
                columns: Array(
                    repeating: GridItem(.flexible(minimum: 0), spacing: JournalMetrics.dotGap),
                    count: JournalCalendar.weekdayCount
                ),
                spacing: JournalMetrics.dotGap
            ) {
                ForEach(Array(JournalCalendar.grid(for: month).enumerated()), id: \.offset) { _, day in
                    JournalZoomDot(day: day, count: day.flatMap { store.day($0) }, today: AteDay.containing(now))
                }
            }
        }
        .contentShape(.rect)
    }
}

/// One day in a small month: ink for a visit, larger butter for a 5.0, larger brick for a 6, the
/// quiet colour for a day gone by without one, a quiet ring for a day still to come.
private struct JournalZoomDot: View {
    let day: AteDay?
    let count: JournalDayCount?
    let today: AteDay

    var body: some View {
        ZStack {
            if let day { dot(day) }
        }
        .frame(maxWidth: .infinity)
        .frame(height: JournalMetrics.dotRow)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func dot(_ day: AteDay) -> some View {
        switch (count?.mark, day > today) {
        case (.six?, _):
            Circle().fill(AteCalendarColor.six).frame(width: JournalMetrics.largeDot, height: JournalMetrics.largeDot)
        case (.five?, _):
            Circle().fill(AteCalendarColor.five).frame(width: JournalMetrics.largeDot, height: JournalMetrics.largeDot)
        case (.visit?, _):
            Circle()
                .fill(AtePalette.automatic.fg)
                .frame(width: JournalMetrics.smallDot, height: JournalMetrics.smallDot)
        case (nil, true):
            Circle()
                .strokeBorder(AteCalendarColor.quiet, lineWidth: JournalMetrics.quietRim)
                .frame(width: JournalMetrics.smallDot, height: JournalMetrics.smallDot)
        case (nil, false):
            Circle().fill(AteCalendarColor.quiet).frame(width: JournalMetrics.smallDot, height: JournalMetrics.smallDot)
        }
    }
}
