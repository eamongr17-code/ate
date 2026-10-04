import Foundation

/// **How far the Journal is zoomed out** (rebuild, 3 Oct): the list, one month, or the year — a
/// zoom of the same page, never a sheet. The calendar button toggles the list and the month; a pinch
/// steps list, month, year; a day tapped in the month zooms back in to the list at that day.
public enum JournalZoom: Hashable, Sendable {
    case list, month, year

    /// A pinch past these reads as a zoom: fingers together below, apart above.
    public static let pinchOut = 0.8
    public static let pinchIn = 1.25

    /// The calendar button, a plain toggle (build 87: "tap twice to get back is a bad pattern"):
    /// the list opens the month, and the month or the year closes back to the list in one tap. The
    /// year is reached from a month's year (build 88).
    public var toggled: JournalZoom {
        switch self {
        case .list: .month
        case .month, .year: .list
        }
    }

    /// Where a pinch that ended at `magnification` takes the page, or `nil` when it was too small
    /// to count — or would zoom past either end.
    public func pinched(_ magnification: Double) -> JournalZoom? {
        if magnification < Self.pinchOut {
            switch self {
            case .list: return .month
            case .month: return .year
            case .year: return nil
            }
        }
        if magnification > Self.pinchIn {
            switch self {
            case .list: return nil
            case .month: return .list
            case .year: return .month
            }
        }
        return nil
    }

    /// The calendar's level, as its telemetry names it; `nil` for the list.
    public var calendarLevel: BrowseEvents.CalendarLevel? {
        switch self {
        case .list: nil
        case .month: .month
        case .year: .year
        }
    }
}

public extension BrowseFilters {
    /// The chips that show under the bar — only the filters that are on, in the sheet's order, and
    /// never the order on Saved (which has none).
    func activeChips(on shelf: BrowseChip.Shelf) -> [BrowseChip] {
        BrowseChip.chips(on: shelf).filter { isActive($0) }
    }

    /// Whether anything at all is on, for `shelf`.
    func isFiltering(on shelf: BrowseChip.Shelf) -> Bool {
        activeChips(on: shelf).isEmpty == false
    }
}
