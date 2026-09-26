import Foundation

/// **Ate's web address, and everything that hangs off it** — the two documents Settings links to,
/// and the link a shared profile carries.
///
/// One constant, in one file, because the App Store listing, the sign-in screen, the settings rows
/// and every share must all point at the same host — several copies of a domain is how one of them
/// ends up 404ing after the real one is registered.
///
/// **The domain is a placeholder.** Eamon owes the real one (AGENTS.md escalation c — nothing
/// public-facing is chosen by the org). Until then the rows still draw and the share still sends,
/// pointed at `ate.app`, and the day the domain lands it changes here once.
public enum AteLegal {
    /// PLACEHOLDER — awaiting Eamon's domain.
    public static let site = URL(string: "https://ate.app")!
    /// PLACEHOLDER — awaiting Eamon.
    public static let privacy = site.appending(path: "privacy")
    /// PLACEHOLDER — awaiting Eamon.
    public static let terms = site.appending(path: "terms")

    /// Where a shared profile points: `<site>/@handle`. Nil for a handle that could not be one.
    public static func profile(handle: String) -> URL? {
        guard HandleName.isWellFormed(handle) else { return nil }
        return site.appending(path: "@" + handle)
    }

    /// Whether the links have been replaced with real ones yet. The report, the digest and any
    /// future release checklist can read this rather than re-deriving it by eye.
    public static var arePlaceholders: Bool { site.host() == "ate.app" }
}
