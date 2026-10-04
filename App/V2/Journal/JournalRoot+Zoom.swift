import AteKit
import SwiftUI

/// The calendar, as a zoom of the Journal: the months, then (by a pinch) the years, in place under the
/// same bar and segment — and a day tapped zooms back in to the list at that day.
extension JournalRoot {

    /// The calendar control (a toggle), or a pinch: to `next`, counted as the calendar's level.
    func step(to next: JournalZoom, via way: BrowseEvents.CalendarWay) {
        if zoom == .list, next == .month {
            // Out to the month the list is in.
            calendarMonth = topMonth ?? AteMonth.containing(Date())
        }
        if let level = next.calendarLevel {
            app.services.analytics(BrowseEvents.calendarOpened(level, via: way))
        }
        zoom = next
    }

    func zoomed(proxy: ScrollViewProxy) -> some View {
        VStack(spacing: 0) {
            segment
            JournalZoomView(
                store: journal.calendarDays,
                zoom: zoom,
                month: $calendarMonth,
                onDay: { openDay($0, proxy: proxy) },
                onMonth: { month in
                    calendarMonth = month
                    step(to: .month, via: .segment)
                }
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .ateGround()
        .contentShape(.rect)
        .simultaneousGesture(MagnifyGesture().onEnded { value in
            guard let next = zoom.pinched(value.magnification) else { return }
            if next == .list {
                zoom = .list
            } else {
                step(to: next, via: .pinch)
            }
        })
        .accessibilityIdentifier("journal.calendar.\(zoom == .year ? "year" : "month")")
    }

    /// A day tapped: the Journal, read on until the day is in it, and the list back — at that day.
    /// A list ordered by score has no days, so it goes back to newest first, its filters kept.
    private func openDay(_ day: AteDay, proxy: ScrollViewProxy) {
        Task {
            if journal.query.sort.isChronological == false {
                var next = filters
                next.sort = .newest
                await journal.apply(next.journalQuery)
            }
            let landing = await journal.reveal(day)
            if let landing {
                let dividers = JournalMonthDividers.dividers(for: journal.entries, sort: journal.query.sort)
                let target = dividers[landing.id] != nil ? Self.dividerID(landing.id) : Self.gapID(landing.id)
                jump(to: target, proxy: proxy)
            }
            let exact = landing.map { AteDay.containing($0.createdAt) == day } ?? false
            app.services.analytics(BrowseEvents.calendarDayOpened(exact: exact))
            zoom = .list
        }
    }
}
