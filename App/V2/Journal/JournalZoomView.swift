import AteKit
import SwiftUI

/// **The Journal zoomed out** — a month, or the year, paging sideways under the same bar.
///
/// The month: days you wrote are photo tiles, a 5.0 day ringed in butter and a 6 in brick; a day you
/// wrote with no photo is its numeral over an ink dot; today, unwritten, is its numeral on an ink
/// disc. The year: twelve small months of dots, the 5.0 days in butter and the 6s in brick, larger.
/// No legend, no back control: the calendar control and a pinch are the way in and out.
struct JournalZoomView: View {
    let store: JournalCalendarStore
    let zoom: JournalZoom
    @Binding var month: AteMonth
    var now = Date()
    let onDay: (AteDay) -> Void
    let onMonth: (AteMonth) -> Void

    private var current: AteMonth { AteMonth.containing(now) }

    var body: some View {
        Group {
            switch zoom {
            case .year: years.transition(.opacity)
            default: months.transition(.opacity)
            }
        }
        .task { await store.loadFirstYear() }
        .task(id: month.year) { await store.loadYear(month.year) }
    }

    // MARK: - Months

    private var monthRange: [AteMonth] {
        let firstYear = min(store.firstYear ?? current.year, month.year)
        let first = AteMonth(year: firstYear, month: 1)
        return (0...max(first.distance(to: current), 0)).map { first.adding(months: $0) }
    }

    /// The months page sideways — the system's own pager, opening on the month asked for.
    private var months: some View {
        TabView(selection: $month) {
            ForEach(monthRange, id: \.self) { page in
                JournalZoomMonth(month: page, store: store, now: now, onDay: onDay)
                    .padding(.horizontal, AteMetrics.loose)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .tag(page)
                    .task { await store.loadYear(page.year) }
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
    }

    // MARK: - Years

    private var yearRange: [Int] {
        Array(min(store.firstYear ?? current.year, month.year)...current.year)
    }

    private var years: some View {
        TabView(selection: Binding(get: { month.year }, set: { year in
            guard year != month.year else { return }
            month = AteMonth(year: year, month: year == current.year ? current.month : 12)
        })) {
            ForEach(yearRange, id: \.self) { year in
                JournalZoomYear(year: year, store: store, now: now, onMonth: onMonth)
                    .padding(.horizontal, AteMetrics.loose)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .tag(year)
                    .task { await store.loadYear(year) }
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
    }
}

/// A zoomed-out page's title: the month (or the year) large, and what it adds up to beside it.
private struct JournalZoomTitle: View {
    let title: String
    let trailing: [String]

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: AteMetrics.regular) {
            Text(title)
                .ateTextLine(.monthTitle)
                .foregroundStyle(AtePalette.automatic.fg)
                .lineLimit(1)
            Spacer(minLength: 0)
            if trailing.isEmpty == false {
                AteMetaParts(parts: trailing)
            }
        }
        .padding(.horizontal, AteMetrics.tight)
        .padding(.top, AteMetrics.loose)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

// MARK: - A month

private struct JournalZoomMonth: View {
    let month: AteMonth
    let store: JournalCalendarStore
    let now: Date
    let onDay: (AteDay) -> Void

    private let columns = Array(
        repeating: GridItem(.flexible(minimum: 0), spacing: JournalMetrics.cellGap),
        count: JournalCalendar.weekdayCount
    )

    var body: some View {
        VStack(alignment: .leading, spacing: AteMetrics.loose) {
            JournalZoomTitle(title: month.name(), trailing: [String(month.year)])
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
            let summary = store.summary(of: month)
            if summary.visits > 0 {
                AteMetaParts(parts: summary.parts)
                    .padding(.horizontal, AteMetrics.tight)
            }
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
