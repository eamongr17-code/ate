import Foundation

/// A place in the app that a link can point at.
public enum AteLink: Equatable, Sendable {
    /// One entry: someone's review, opened on its own page.
    case entry(UUID)
}

/// **Links into the app** — what a shared review sends, and what the app opens.
///
/// Sharing somebody else's entry sends a link to it, not a picture (round 5, Eamon): whoever gets it
/// opens the review inside Ate. A person's OWN entry still shares its printed receipt.
///
/// App-only for now (Eamon, round 5): there is no domain yet and no web fallback, so the link is the
/// app's own scheme, `ate://entry/<id>`. ``base`` is the ONE value to change when a domain lands —
/// every link is built from it and every incoming link is read against it.
public enum AteLinks {
    /// **The one config value.** Where every link starts. A custom scheme until Eamon picks a
    /// domain; then `https://<domain>/` (plus the associated-domains entitlement).
    public static let base = URL(string: "ate://")!

    /// The custom scheme the app registers (`CFBundleURLTypes`). Always understood, whatever
    /// ``base`` becomes, so a link already sent keeps opening.
    public static let scheme = "ate"

    /// The path segment an entry link carries.
    static let entrySegment = "entry"

    /// `ate://entry/<id>` — the link a shared entry sends. Ids are lowercased, as Postgres writes them.
    public static func entry(_ id: UUID) -> URL {
        entry(id, base: base)
    }

    static func entry(_ id: UUID, base: URL) -> URL {
        URL(string: base.absoluteString + entrySegment + "/" + id.uuidString.lowercased())!
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
        guard segments.count == 2, segments[0].lowercased() == entrySegment,
              let id = UUID(uuidString: segments[1]) else { return nil }
        return .entry(id)
    }
}
