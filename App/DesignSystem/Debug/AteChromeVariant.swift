import Foundation

/// **Round-5 chrome explorations** — two working variants of each visual item, picked at launch
/// with `-ate-r5-<item> A|B` (A when absent). Exploration only: once Eamon picks, the loser and this
/// switch go.
enum AteChromeVariant: String, Sendable {
    case a = "A", b = "B"

    /// The status-bar frost: A a gradient frost, B an even blur band.
    static let frost = value(for: "frost")
    /// The floating header's return: A a blur-to-sharp fade, B a slide with a frosted scrim.
    static let header = value(for: "header")
    /// The tab bar's expand and minimise: A a spring morph, B a drop-and-rise swap.
    static let nav = value(for: "nav")

    private static func value(for item: String) -> AteChromeVariant {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-ate-r5-\(item)"), index + 1 < arguments.count else { return .a }
        return AteChromeVariant(rawValue: arguments[index + 1].uppercased()) ?? .a
    }
}
