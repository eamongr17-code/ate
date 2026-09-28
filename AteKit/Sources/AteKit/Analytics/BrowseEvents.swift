import Foundation

/// Round 4's browse signals: the journal's filter and sort, and the photo preview. Built here so the
/// names and parameters are asserted by tests; sent by the app's ``AnalyticsRecorder``.
public enum BrowseEvents {
    /// The journal was re-queried: a sort picked, a filter added or a pill removed. Names only —
    /// never a place, a score or a month, which are the person's own record.
    public static func journalQueried(_ query: JournalQuery, resultCount: Int) -> AnalyticsEvent {
        AnalyticsEvent(name: "journal_queried", parameters: [
            "sort": query.sort.rawValue,
            "filters": query.filterNames,
            "result_count": String(resultCount)
        ])
    }

    /// Where the one filter sheet was opened from.
    public enum FilterSurface: String, Sendable {
        case journal, saved, search
    }

    /// The Saved shelf was narrowed (round 5): which filters, never their values.
    public static func savedFiltered(_ filter: SavedDishFilter, resultCount: Int) -> AnalyticsEvent {
        var names: [String] = []
        if filter.band.minScore != nil { names.append("min_score") }
        if filter.band.maxScore != nil { names.append("max_score") }
        if filter.city != nil { names.append("city") }
        if filter.window.isAll == false { names.append("window") }
        return AnalyticsEvent(name: "saved_filtered", parameters: [
            "filters": names.isEmpty ? "none" : names.joined(separator: ","),
            "result_count": String(resultCount)
        ])
    }

    /// The filter sheet was opened — the same sheet on the Journal and on Search.
    public static func filterOpened(on surface: FilterSurface) -> AnalyticsEvent {
        AnalyticsEvent(name: "filter_opened", parameters: ["surface": surface.rawValue])
    }

    /// A filter chip's sheet was opened (round 7) — which chip, on which shelf.
    public static func chipOpened(_ chip: BrowseChip, on surface: FilterSurface) -> AnalyticsEvent {
        AnalyticsEvent(name: "filter_chip_opened", parameters: ["chip": chip.rawValue, "surface": surface.rawValue])
    }

    /// An active chip's cross, or its sheet's Clear, took its filter off.
    public static func chipCleared(_ chip: BrowseChip, on surface: FilterSurface) -> AnalyticsEvent {
        AnalyticsEvent(name: "filter_chip_cleared", parameters: ["chip": chip.rawValue, "surface": surface.rawValue])
    }

    /// The journal's calendar (round 7): which view, and how it was reached.
    public enum CalendarLevel: String, Sendable { case month, year }
    public enum CalendarWay: String, Sendable { case button, pinch, segment }

    public static func calendarOpened(_ level: CalendarLevel, via way: CalendarWay) -> AnalyticsEvent {
        AnalyticsEvent(name: "calendar_opened", parameters: ["level": level.rawValue, "via": way.rawValue])
    }

    /// A day on the calendar was tapped and the list came back scrolled to it. `landed` is `day`
    /// when the day itself is in the list, `nearest` when the filters left it out.
    public static func calendarDayOpened(exact: Bool) -> AnalyticsEvent {
        AnalyticsEvent(name: "calendar_day_opened", parameters: ["landed": exact ? "day" : "nearest"])
    }

    /// A photo was opened large. `photo_count` is how many the viewer can swipe through.
    public static func photoPreviewOpened(photoCount: Int) -> AnalyticsEvent {
        AnalyticsEvent(name: "photo_preview_opened", parameters: ["photo_count": String(photoCount)])
    }

    /// The entry page drew from the card it was opened with, before its own read answered.
    /// `seeded=false` is an entry opened by id alone (a dish page's review), which drew skeletons.
    public static func entryOpened(seeded: Bool) -> AnalyticsEvent {
        AnalyticsEvent(name: "entry_opened", parameters: ["seeded": seeded ? "true" : "false"])
    }
}
