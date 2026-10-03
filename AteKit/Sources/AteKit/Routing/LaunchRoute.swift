#if DEBUG
import Foundation

/// **Where a Debug launch opens** — a route, read the way a link is: `entry/<id>` is `ate://entry/<id>`,
/// and goes through ``AteLinks`` like any link a person taps. The rest of the app's places are the
/// shell's own `Route` cases and its tabs and covers, named the same way.
///
/// A screen's starting state rides on the link's query — `journal?filtered`,
/// `entry/<id>?sheet=place`, `search/dishes?q=ra&filter` — and a query item a screen does not take is
/// a typo, so the whole route is refused rather than half-opened. What is written where is listed on
/// ``Screen`` and ``Option``; the launch argument itself is ``DebugLaunch``'s.
public struct LaunchRoute: Equatable, Sendable {
    public enum Screen: Equatable, Sendable {
        // Tabs.
        case journal
        /// The Journal on its Saved shelf.
        case saved
        case feed
        case search(SearchScope)
        case you
        // Pages, pushed on the tab they are normally reached from.
        case entry(UUID)
        case profile(UUID)
        case place(UUID)
        case dish(UUID)
        case suggestions
        /// One bar of the You histogram.
        case ratings(score: Double)
        case statement(StatementMonth)
        /// Settings, or one of the pages it pushes.
        case settings(SettingsPage?)
        // Covers, and the screens before the tabs.
        case composer
        /// The Summary after Done, on an entry already written.
        case summary(UUID)
        case welcome
        /// The first-run handle step, which has no way back and is otherwise reached only by a
        /// brand-new Apple ID.
        case firstRunHandle
        /// The component kit's gallery — every atom and composite in every state, pushed from the
        /// foot of Settings.
        case kit
    }

    public enum SettingsPage: String, Sendable, CaseIterable {
        case handle, appearance, ai, blocked
    }

    /// A screen's starting state, as a query item.
    public enum Option: String, Sendable, CaseIterable {
        /// Journal: Rating 4.0 and up. Search: vegetarian, 4.0 and up (with ``window``).
        case filtered
        /// The filter sheet (Search) or the Rating chip's sheet (Journal), open over the list.
        case filter
        /// Search: `window=custom` (March to August 2026) or `window=preset` (This year).
        case window
        /// Search: the words in the field.
        case query = "q"
        /// Feed: the location sheet, open.
        case location
        /// Entry: `sheet=place`, `sheet=dish` (the first dish's) or `sheet=share`.
        case sheet
        /// `AddPlace` over whichever place sheet opens first (the entry's or the composer's).
        case addPlace = "add-place"
        /// Composer: the star slider open on the first score.
        case score
        /// Composer: the caret parked straight after the first score pill.
        case caret
        /// Composer: the camera's cover, as a stand-in that shoots the ragù after a few seconds.
        case camera
        /// Composer: a capture without a camera — the ragù lands through the camera key's own path.
        case capture
        /// Summary: still printing (the lines have not arrived).
        case printing
        /// Summary: written with no place, so the receipt waits on the Place key.
        case noPlace = "no-place"

        /// The values an option is limited to, when it is not free text or a bare switch.
        var values: Set<String>? {
            switch self {
            case .sheet: ["place", "dish", "share"]
            case .window: ["custom", "preset"]
            default: nil
            }
        }
    }

    public let screen: Screen
    /// The query items, by name. A bare item (`?filtered`) is the empty string.
    public let options: [Option: String]

    public init(screen: Screen, options: [Option: String] = [:]) {
        self.screen = screen
        self.options = options
    }

    public func has(_ option: Option) -> Bool { options[option] != nil }

    public func value(_ option: Option) -> String? { options[option] }

    /// Reads `<route>` as `ate://<route>`. `nil` for anything that is not a screen, or that carries a
    /// query item its screen does not take.
    public init?(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: AteLinks.scheme + "://" + encoded),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let host = components.host?.lowercased() else { return nil }
        let path = [host] + components.path.split(separator: "/").map(String.init)
        guard let screen = Self.screen(path, url: url) else { return nil }
        var options: [Option: String] = [:]
        for item in components.queryItems ?? [] {
            guard let option = Option(rawValue: item.name), Self.takes(screen).contains(option) else { return nil }
            let value = item.value ?? ""
            if let allowed = option.values, allowed.contains(value) == false { return nil }
            options[option] = value
        }
        self.init(screen: screen, options: options)
    }

    /// The screens named by one word.
    private static let words: [String: Screen] = [
        "journal": .journal, "saved": .saved, "feed": .feed, "you": .you, "suggestions": .suggestions,
        "composer": .composer, "welcome": .welcome, "first-run-handle": .firstRunHandle,
        "settings": .settings(nil), "search": .search(.places), "kit": .kit
    ]

    /// The pages named by an id.
    private static let pages: [String: @Sendable (UUID) -> Screen] = [
        "profile": { .profile($0) }, "place": { .place($0) }, "dish": { .dish($0) }, "summary": { .summary($0) }
    ]

    private static func screen(_ path: [String], url: URL) -> Screen? {
        if path.count == 1 { return words[path[0]] }
        guard path.count == 2 else { return nil }
        let tail = path[1]
        if let page = pages[path[0]] { return UUID(uuidString: tail).map(page) }
        switch path[0] {
        // An entry is the one place a shared link already goes: read it the way a tapped link is.
        case "entry":
            guard case .entry(let id)? = AteLinks.parse(url) else { return nil }
            return .entry(id)
        case "settings": return SettingsPage(rawValue: tail).map { .settings($0) }
        case "search": return SearchScope(rawValue: tail).map { .search($0) }
        case "ratings": return Double(tail).map { .ratings(score: $0) }
        case "statement": return StatementMonth(iso: tail).map { .statement($0) }
        default: return nil
        }
    }

    /// The query items each screen takes.
    private static func takes(_ screen: Screen) -> Set<Option> {
        switch screen {
        case .journal: [.filtered, .filter]
        case .feed: [.location]
        case .search: [.query, .filtered, .filter, .window]
        case .entry: [.sheet, .addPlace]
        case .composer: [.score, .caret, .camera, .capture, .addPlace]
        case .summary: [.printing, .noPlace]
        default: []
        }
    }
}
#endif
