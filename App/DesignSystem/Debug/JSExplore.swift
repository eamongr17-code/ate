import AteKit
import Foundation

/// **Round 5 explorations for the Journal and Search** — `-ate-r5-<item> A|B|C` picks a variant at
/// launch so each can be photographed for Eamon. Temporary: once he picks, the pick is built for
/// real and this file goes. Absent (and in any Release build) is variant A.
enum JSExplore {
    enum Variant: String {
        // swiftlint:disable:next identifier_name
        case a = "A", b = "B", c = "C"
    }

    /// `-ate-r5-journal-header`: the Journal's header — A masthead, B one bar, C logo and rail.
    static var journalHeader: Variant { variant("journal-header") }
    /// `-ate-r5-filter-sheet`: the one filter sheet — A slider and radio rows, B ruler and pills.
    static var filterSheet: Variant { variant("filter-sheet") }
    /// `-ate-r5-search`: the Search tab — A filter beside the field, B one segment, C filter in the
    /// title row.
    static var search: Variant { variant("search") }
    /// `-ate-r5-launch`: the launch moment — A the logo lands in the Journal's header, B the app
    /// icon's coral opens onto the app.
    static var launch: Variant { variant("launch") }

    /// Stand-in cities until the backend lane publishes its city contract.
    static let fakeCities = [
        AteCity(city: "melbourne", name: "Melbourne", region: "VIC"),
        AteCity(city: "sydney", name: "Sydney", region: "NSW"),
        AteCity(city: "hobart", name: "Hobart", region: "TAS")
    ]

    /// `-ate-r5-feed-location`: the Feed's location — A a chip beside the title and radio rows, B
    /// the city as the page's title and a wrap of pills.
    static var feedLocation: Variant { variant("feed-location") }
    /// `-ate-r5-feed-location-open`: the Feed's location sheet is open at launch.
    static var feedLocationOpen: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("-ate-r5-feed-location-open")
        #else
        false
        #endif
    }

    #if DEBUG
    /// `-ate-r5-journal-filtered`: the Journal starts with a demo range and order on.
    static var journalFiltered: Bool { ProcessInfo.processInfo.arguments.contains("-ate-r5-journal-filtered") }
    /// `-ate-r5-filter-open`: the Journal's filter sheet is open at launch.
    static var journalFilterOpen: Bool { ProcessInfo.processInfo.arguments.contains("-ate-r5-filter-open") }
    #else
    static let journalFiltered = false
    static let journalFilterOpen = false
    #endif

    private static func variant(_ item: String) -> Variant {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-ate-r5-\(item)"), arguments.indices.contains(index + 1) else {
            return .a
        }
        return Variant(rawValue: arguments[index + 1].uppercased()) ?? .a
        #else
        return .a
        #endif
    }
}
