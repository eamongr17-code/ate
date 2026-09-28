import AteKit
import SwiftUI

/// **The journal's calendar** (round 7, `CalendarMonth` / `CalendarYear`) — opened from the header's
/// calendar button or by pinching the list. The month: every day a tile, a day you wrote carrying its
/// photo, a 5.0 day ringed in butter with a ★5, a 6 day in brick with a ★6. Pinched again (or the
/// segment), the year: twelve small months of dots, the 5s and 6s larger, and a legend. A day takes
/// you back to the list, at that day; a small month opens itself. Months and years page sideways.
struct JournalCalendarView: View {
    let store: JournalCalendarStore
    @Binding var level: BrowseEvents.CalendarLevel
    @Binding var month: AteMonth
    var now = Date()
    let onBack: () -> Void
    let onDay: (AteDay) -> Void
    /// A change of view by the segment or a pinch — for the telemetry.
    let onLevel: (BrowseEvents.CalendarLevel, BrowseEvents.CalendarWay) -> Void

    @State private var shownYear: Int?

    private var current: AteMonth { AteMonth.containing(now) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            topRow
                .padding(.horizontal, AteCalendarMetrics.side)
            switch level {
            case .month: months.transition(.opacity)
            case .year: years.transition(.opacity)
            }
            Spacer(minLength: 0)
        }
        .ateContentTop()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .ateGround()
        .contentShape(.rect)
        .simultaneousGesture(pinch)
        .task { await store.loadFirstYear() }
        .task(id: month.year) { await store.loadYear(month.year) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("calendar")
    }

    // MARK: - The top row

    /// `CalendarMonth`: the back disc, the Month | Year segment centred, and a disc's width of air.
    private var topRow: some View {
        HStack(spacing: AteMetrics.snug) {
            AteGlassButton(icon: .back, label: "Back to list", size: AteNavigationBarMetrics.backIcon, action: onBack)
                .accessibilityIdentifier("calendar.back")
            Spacer(minLength: 0)
            AteSegments(
                options: [AteSegment(BrowseEvents.CalendarLevel.month, "Month"), AteSegment(.year, "Year")],
                selection: Binding(get: { level }, set: { next in
                    guard next != level else { return }
                    onLevel(next, .segment)
                }),
                hugs: true,
                identifier: "calendar.level"
            )
            .fixedSize()
            Spacer(minLength: 0)
            Color.clear.frame(width: AteMetrics.hit, height: AteMetrics.hit)
        }
    }

    // MARK: - Pinch

    /// Fingers together zooms out — the list to the month, the month to the year; apart zooms back in.
    private var pinch: some Gesture {
        MagnifyGesture()
            .onEnded { value in
                if value.magnification < AteCalendarMetrics.pinchOut, level == .month {
                    onLevel(.year, .pinch)
                } else if value.magnification > AteCalendarMetrics.pinchIn {
                    switch level {
                    case .year: onLevel(.month, .pinch)
                    case .month: onBack()
                    }
                }
            }
    }

    // MARK: - The month

    private var monthRange: [AteMonth] {
        let firstYear = min(store.firstYear ?? current.year, month.year)
        let first = AteMonth(year: firstYear, month: 1)
        return (0...max(first.distance(to: current), 0)).map { first.adding(months: $0) }
    }

    /// The months page sideways — the system's own pager, which opens on the month asked for.
    private var months: some View {
        TabView(selection: $month) {
            ForEach(monthRange, id: \.self) { page in
                JournalCalendarMonth(month: page, store: store, now: now, onDay: onDay)
                    .padding(.horizontal, AteCalendarMetrics.side)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .tag(page)
                    .task { await store.loadYear(page.year) }
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .padding(.top, AteCalendarMetrics.gap)
    }

    // MARK: - The year

    private var yearRange: [Int] {
        Array(min(store.firstYear ?? current.year, month.year)...current.year)
    }

    private var years: some View {
        TabView(selection: Binding(get: { month.year }, set: { year in
            guard year != month.year else { return }
            month = AteMonth(year: year, month: year == current.year ? current.month : 12)
        })) {
            ForEach(yearRange, id: \.self) { year in
                JournalCalendarYear(year: year, store: store, now: now) { picked in
                    month = picked
                    onLevel(.month, .segment)
                }
                .padding(.horizontal, AteCalendarMetrics.side)
                .frame(maxHeight: .infinity, alignment: .top)
                .tag(year)
                .task { await store.loadYear(year) }
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .padding(.top, AteCalendarMetrics.yearGap)
    }
}

enum AteCalendarMetrics {
    /// `padding: 58px 16px 0; gap: 16px` (the year: 14).
    static let side: CGFloat = 16
    static let gap: CGFloat = 16
    static let yearGap: CGFloat = 14
    /// The title row's own `padding: 4px 4px 0`.
    static let titleInset: CGFloat = 4
    /// The grid's `gap: 6px`, and a tile's corner.
    static let cellGap: CGFloat = 6
    static let tileCorner: CGFloat = 14
    /// A ★ day's ring: `box-shadow: 0 0 0 3px`.
    static let ring: CGFloat = 3
    /// The badge: `right: -4px; top: -6px; padding: 0 5px`.
    static let badgeRight: CGFloat = -4
    static let badgeTop: CGFloat = -6
    static let badgePadding: CGFloat = 5
    /// A pinch past these reads as a zoom: fingers together below, apart above.
    static let pinchOut: CGFloat = 0.8
    static let pinchIn: CGFloat = 1.25
}

// MARK: - A month

/// One month of the calendar: its name and year, the weekday initials, the tiles, and its line.
private struct JournalCalendarMonth: View {
    let month: AteMonth
    let store: JournalCalendarStore
    let now: Date
    let onDay: (AteDay) -> Void

    private let columns = Array(
        repeating: GridItem(.flexible(minimum: 0), spacing: AteCalendarMetrics.cellGap),
        count: JournalCalendar.weekdayCount
    )

    var body: some View {
        VStack(alignment: .leading, spacing: AteCalendarMetrics.gap) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(month.name())
                    .ateTextLine(.monthTitle)
                    .foregroundStyle(AtePalette.automatic.fg)
                Spacer(minLength: 0)
                Text(String(month.year))
                    .ateText(.calendarYear)
                    .foregroundStyle(AtePalette.automatic.muted)
            }
            .padding(.horizontal, AteCalendarMetrics.titleInset)
            .padding(.top, AteCalendarMetrics.titleInset)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            LazyVGrid(columns: columns, spacing: AteCalendarMetrics.cellGap) {
                ForEach(Array(JournalCalendar.weekdayInitials().enumerated()), id: \.offset) { _, initial in
                    Text(initial)
                        .ateText(.calendarWeekday)
                        .foregroundStyle(AtePalette.automatic.muted)
                        .accessibilityHidden(true)
                }
            }
            LazyVGrid(columns: columns, spacing: AteCalendarMetrics.cellGap) {
                ForEach(Array(JournalCalendar.grid(for: month).enumerated()), id: \.offset) { _, day in
                    if let day {
                        JournalCalendarDay(day: day, count: store.day(day), onTap: { onDay(day) })
                    } else {
                        Color.clear.aspectRatio(1, contentMode: .fit)
                    }
                }
            }
            summary
        }
    }

    @ViewBuilder
    private var summary: some View {
        let summary = store.summary(of: month)
        if summary.visits > 0 {
            AteMetaParts(parts: summary.parts)
                .padding(.horizontal, AteCalendarMetrics.titleInset)
                .padding(.vertical, 6)
        }
    }
}

/// One day's square: its photo and number when you wrote that day — ringed and badged for a 5.0 or
/// a 6 — or just the number, muted, when you did not.
private struct JournalCalendarDay: View {
    let day: AteDay
    let count: JournalDayCount?
    let onTap: () -> Void

    var body: some View {
        if let count {
            Button(action: onTap) { tile(count) }
                .buttonStyle(.plain)
                .accessibilityLabel(accessibilityLabel(count))
                .accessibilityIdentifier("calendar.day.\(day.string)")
        } else {
            Color.clear
                .aspectRatio(1, contentMode: .fit)
                .overlay {
                    Text(String(day.day))
                        .ateText(.calendarDay)
                        .foregroundStyle(AtePalette.automatic.muted)
                        .fixedSize()
                }
                .accessibilityHidden(true)
        }
    }

    private func tile(_ count: JournalDayCount) -> some View {
        let shape = RoundedRectangle(cornerRadius: AteCalendarMetrics.tileCorner, style: .continuous)
        let hasPhoto = count.coverURL != nil
        return Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let cover = count.coverURL {
                    AtePhotoContent(photo: .remote(cover), size: .forSide(56))
                } else {
                    accent
                }
            }
            .overlay(alignment: .bottomLeading) {
                Text(String(day.day))
                    .ateText(.calendarDayOnPhoto)
                    .foregroundStyle(hasPhoto ? AteCalendarColor.overPhoto : AteColor.ink)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
            }
            .clipShape(shape)
            .overlay {
                if let ring = ringColour(count.mark) {
                    shape.strokeBorder(ring, lineWidth: AteCalendarMetrics.ring)
                        .padding(-AteCalendarMetrics.ring)
                }
            }
            .overlay(alignment: .topTrailing) { badge(count.mark) }
    }

    /// A day you wrote without a photo: its square in one accent, never butter (which means a score) —
    /// the letter tile's rule, picked from the day.
    private var accent: some View {
        DishLetter.accents[(day.day + day.month) % DishLetter.accents.count]
    }

    private func ringColour(_ mark: JournalDayMark) -> Color? {
        switch mark {
        case .five: AteCalendarColor.five
        case .six: AteCalendarColor.six
        case .visit: nil
        }
    }

    @ViewBuilder
    private func badge(_ mark: JournalDayMark) -> some View {
        switch mark {
        case .five: badge("★5", fill: AteCalendarColor.five, ink: AteCalendarColor.fiveInk)
        case .six: badge("★6", fill: AteCalendarColor.six, ink: AteCalendarColor.sixInk)
        case .visit: EmptyView()
        }
    }

    private func badge(_ text: String, fill: Color, ink: Color) -> some View {
        Text(text)
            .ateText(.calendarBadge)
            .foregroundStyle(ink)
            .padding(.horizontal, AteCalendarMetrics.badgePadding)
            .background(fill, in: .capsule)
            .fixedSize()
            .offset(x: -AteCalendarMetrics.badgeRight, y: AteCalendarMetrics.badgeTop)
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

/// One year: its number and its line, twelve small months of dots, and the legend.
private struct JournalCalendarYear: View {
    let year: Int
    let store: JournalCalendarStore
    let now: Date
    let onMonth: (AteMonth) -> Void

    private let columns = Array(
        repeating: GridItem(.flexible(minimum: 0), spacing: 18, alignment: .topLeading), count: 3
    )

    var body: some View {
        VStack(alignment: .leading, spacing: AteCalendarMetrics.yearGap) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(String(year))
                    .ateTextLine(.monthTitle)
                    .foregroundStyle(AtePalette.automatic.fg)
                Spacer(minLength: 0)
                let summary = store.summary(ofYear: year)
                if summary.visits > 0 {
                    AteMetaParts(parts: summary.parts)
                }
            }
            .padding(.horizontal, AteCalendarMetrics.titleInset)
            .padding(.top, AteCalendarMetrics.titleInset)
            LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
                ForEach(1...12, id: \.self) { index in
                    let month = AteMonth(year: year, month: index)
                    Button { onMonth(month) } label: { mini(month) }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(month.name()) \(String(year))")
                        .accessibilityIdentifier("calendar.month.\(index)")
                }
            }
            legend
        }
    }

    private func mini(_ month: AteMonth) -> some View {
        let isPast = month <= AteMonth.containing(now)
        return VStack(alignment: .leading, spacing: 6) {
            Text(month.shortName())
                .ateText(.calendarMiniMonth)
                .foregroundStyle(isPast ? AtePalette.automatic.fg : AtePalette.automatic.muted)
            LazyVGrid(
                columns: Array(
                    repeating: GridItem(.flexible(minimum: 0), spacing: 1), count: JournalCalendar.weekdayCount
                ),
                spacing: 1
            ) {
                ForEach(Array(JournalCalendar.grid(for: month).enumerated()), id: \.offset) { _, day in
                    JournalYearDot(day: day, count: day.flatMap { store.day($0) }, today: AteDay.containing(now))
                }
            }
        }
        .contentShape(.rect)
    }

    private var legend: some View {
        HStack(spacing: 14) {
            legendItem(side: JournalYearDot.small, colour: AtePalette.automatic.fg, "A visit")
            legendItem(side: JournalYearDot.large, colour: AteCalendarColor.five, "A 5.0")
            legendItem(side: JournalYearDot.large, colour: AteCalendarColor.six, "A 6")
        }
        .padding(AteCalendarMetrics.titleInset)
    }

    private func legendItem(side: CGFloat, colour: Color, _ title: String) -> some View {
        HStack(spacing: 6) {
            Circle().fill(colour).frame(width: side, height: side)
            Text(title)
                .ateText(.calendarLegend)
                .foregroundStyle(AtePalette.automatic.muted)
        }
    }
}

/// One day in a small month: a dot — ink for a visit, larger butter for a 5.0, larger brick for a 6,
/// the quiet colour for a day gone by without one, a quiet ring for a day still to come.
private struct JournalYearDot: View {
    let day: AteDay?
    let count: JournalDayCount?
    let today: AteDay

    static let small: CGFloat = 6
    static let large: CGFloat = 10

    var body: some View {
        ZStack {
            if let day {
                dot(day)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 13)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func dot(_ day: AteDay) -> some View {
        switch (count?.mark, day > today) {
        case (.six?, _):
            Circle().fill(AteCalendarColor.six).frame(width: Self.large, height: Self.large)
        case (.five?, _):
            Circle().fill(AteCalendarColor.five).frame(width: Self.large, height: Self.large)
        case (.visit?, _):
            Circle().fill(AtePalette.automatic.fg).frame(width: Self.small, height: Self.small)
        case (nil, true):
            Circle().strokeBorder(AteCalendarColor.quiet, lineWidth: 1).frame(width: Self.small, height: Self.small)
        case (nil, false):
            Circle().fill(AteCalendarColor.quiet).frame(width: Self.small, height: Self.small)
        }
    }
}
