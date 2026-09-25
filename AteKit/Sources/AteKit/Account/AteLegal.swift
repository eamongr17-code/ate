import Foundation

/// **The two documents Settings links to.**
///
/// One constant, in one file, because the App Store listing, the sign-in screen and the settings
/// rows must all point at the same two URLs — three copies of a legal link is how one of them ends
/// up 404ing after a rewrite.
///
/// **These are placeholders.** Eamon owns the words and where they are hosted; nothing public-facing
/// is written by the org (AGENTS.md escalation c). Until he provides them the rows still draw — the
/// artboard has them — and open the site's own placeholder pages.
public enum AteLegal {
    /// PLACEHOLDER — awaiting Eamon.
    public static let privacy = URL(string: "https://ate.app/privacy")!
    /// PLACEHOLDER — awaiting Eamon.
    public static let terms = URL(string: "https://ate.app/terms")!

    /// Whether the links have been replaced with real ones yet. The report, the digest and any
    /// future release checklist can read this rather than re-deriving it by eye.
    public static var arePlaceholders: Bool { privacy.host() == "ate.app" }
}
