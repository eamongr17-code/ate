import Foundation

/// **Round-6 chrome explorations** — picked at launch, gone once Eamon picks.
///
/// - `-ate-r6-feed-icon <AteIcon case>`: the Feed tab's icon candidate (`newspaper`,
///   `utensilsCrossed`, `compass`, `globe`, `layoutList`).
/// - `-ate-r6-header A|B`: the compact floating header. A a centred small title; B a leading small
///   title with the control at the trailing end.
enum AteRound6Explore {
    static let feedIcon: AteIcon? = argument("-ate-r6-feed-icon").flatMap(AteIcon.init(rawValue:))

    static let header: CompactHeaderLayout = argument("-ate-r6-header")?.uppercased() == "B" ? .leading : .centred

    enum CompactHeaderLayout: Sendable {
        case centred, leading
    }

    private static func argument(_ name: String) -> String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }
}
