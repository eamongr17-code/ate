import Foundation

/// A place in the app that a link can point at.
public enum AteLink: Equatable, Sendable {
    /// One entry: someone's review, opened on its own page.
    case entry(UUID)
    /// One list, shared the way a playlist is: a link, never a picture of its lines.
    case list(UUID)
}

/// **Links into the app** — what a shared review sends, and what the app opens.
///
/// Sharing somebody else's entry sends a link to it, not a picture (round 5, Eamon): whoever gets it
/// opens the review inside Ate. A person's OWN entry still shares its printed receipt.
///
/// Links are `https://ate.link/entry/<id>` (Nov 2026): with Ate installed the link opens the app (a
/// universal link, `applinks:ate.link` + the site's apple-app-site-association); without it, the web
/// page (`web/`) shows the post and the way to get the app. Every link is built from ``base`` and every
/// incoming link is read against it; the old `ate://` links already sent keep opening.
public enum AteLinks {
    /// **The one config value.** Where every link starts: the domain in `Config/domain.txt`, which
    /// the associated-domains entitlement (`Config/Ate.entitlements`) and the web pages also use.
    public static let base = URL(string: "https://ate.link/")!

    /// The custom scheme the app registers (`CFBundleURLTypes`). Always understood, whatever
    /// ``base`` becomes, so a link already sent keeps opening.
    public static let scheme = "ate"

    /// The path segment an entry link carries.
    static let entrySegment = "entry"
    /// …and a list link's.
    static let listSegment = "list"

    /// `https://ate.link/entry/<id>` — the link a shared entry sends. Ids are lowercased, as Postgres writes them.
    public static func entry(_ id: UUID) -> URL {
        entry(id, base: base)
    }

    static func entry(_ id: UUID, base: URL) -> URL {
        URL(string: base.absoluteString + entrySegment + "/" + id.uuidString.lowercased())!
    }

    /// `https://ate.link/list/<id>` — the link a shared list sends (Spotify's playlist, not a receipt).
    public static func list(_ id: UUID) -> URL {
        list(id, base: base)
    }

    static func list(_ id: UUID, base: URL) -> URL {
        URL(string: base.absoluteString + listSegment + "/" + id.uuidString.lowercased())!
    }

    /// Reads an incoming link. `nil` for anything that is not one of ours, or not well formed.
    public static func parse(_ url: URL) -> AteLink? {
        parse(url, base: base)
    }

    static func parse(_ url: URL, base: URL) -> AteLink? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased() else { return nil }
        let path = components.path.split(separator: "/").map(String.init)
        let segments: [String]
        if scheme == Self.scheme {
            // `ate://entry/<id>`: the first segment is the URL's host.
            segments = [components.host].compactMap { $0 } + path
        } else if scheme == "https", let host = components.host?.lowercased(),
                  let baseHost = base.host?.lowercased(), base.scheme == "https",
                  host == baseHost || host == "www." + baseHost {
            segments = path
        } else {
            return nil
        }
        guard segments.count == 2, let id = UUID(uuidString: segments[1]) else { return nil }
        switch segments[0].lowercased() {
        case entrySegment: return .entry(id)
        case listSegment: return .list(id)
        default: return nil
        }
    }
}
