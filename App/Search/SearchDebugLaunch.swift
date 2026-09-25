import AteKit
import Foundation

#if DEBUG
/// **Launch arguments that open the Search tab in a state** — the screens a simulator drive
/// photographs, reachable from `simctl launch` because a simulator cannot be typed into from a shell.
///
/// `-ate-open-search` lands on the tab; `-ate-search-scope dishes|people|saved|places` picks the
/// segment and `-ate-search-query <text>` fills the field. Debug only: nothing here exists in a
/// shipped binary.
enum SearchDebugLaunch {
    static let openArgument = "-ate-open-search"
    static let scopeArgument = "-ate-search-scope"
    static let queryArgument = "-ate-search-query"

    static var opensSearch: Bool { arguments.contains(openArgument) }

    static var scope: SearchScope {
        value(after: scopeArgument).flatMap(SearchScope.init(rawValue:)) ?? .places
    }

    static var query: String { value(after: queryArgument) ?? "" }

    private static var arguments: [String] { ProcessInfo.processInfo.arguments }

    private static func value(after flag: String) -> String? {
        guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else {
            return nil
        }
        return arguments[index + 1]
    }
}
#endif
