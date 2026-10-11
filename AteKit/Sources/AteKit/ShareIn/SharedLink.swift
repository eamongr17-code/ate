import Foundation

/// **The link a share sheet handed over.** TikTok shares a URL; Instagram a URL; Safari a URL; some
/// apps only text with a link somewhere inside it ("Look at this! https://vm.tiktok.com/…"). The
/// first https link wins — the share card reads one post, never a list.
public enum SharedLink {
    /// The URL itself when it is https; nothing otherwise (a `file:` or `http:` share is not a post).
    public static func https(_ url: URL?) -> URL? {
        OwnSaveDraft.httpsURL(url?.absoluteString)
    }

    /// The first https link in a run of text, as written (a trailing full stop or bracket is not part
    /// of it).
    public static func find(in text: String?) -> URL? {
        guard let text, text.isEmpty == false,
              let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        else { return nil }
        let whole = NSRange(text.startIndex..., in: text)
        for match in detector.matches(in: text, options: [], range: whole) {
            guard let url = match.url, let found = https(url) else { continue }
            return found
        }
        return nil
    }

    /// The first https link among everything shared: the URL attachments first (they are the
    /// post), then any text.
    public static func find(urls: [URL], texts: [String]) -> URL? {
        for url in urls {
            if let found = https(url) { return found }
        }
        for text in texts {
            if let found = find(in: text) { return found }
        }
        return nil
    }

    /// The shared words that are more than the link itself — a caption some apps pass along, for
    /// `read-share`'s `text`. `nil` when the text was only the link.
    public static func text(_ texts: [String], besides link: URL?) -> String? {
        let joined = texts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.isEmpty == false && $0 != link?.absoluteString }
            .joined(separator: "\n")
        return joined.isEmpty ? nil : joined
    }
}

/// **Where an own save came from, in words** — the link card's two lines. "@sydneyeats on TikTok"
/// over the caption in quotes; "On Instagram" over the link itself when there is no caption.
public enum OwnSaveSourceLine {
    /// "@sydneyeats on TikTok", "On Instagram", or the link's own site.
    public static func title(source: OwnSaveSource, url: String?, author: String?) -> String {
        let site: String
        switch source {
        case .tiktok: site = "TikTok"
        case .instagram: site = "Instagram"
        case .link, .manual: site = host(url) ?? "the web"
        }
        guard let author = author?.trimmingCharacters(in: .whitespacesAndNewlines), author.isEmpty == false else {
            return "On \(site)"
        }
        return "\(author) on \(site)"
    }

    /// The caption in quotes, or — with none — the link, shortened to its site and first step
    /// ("instagram.com/reel/…").
    public static func detail(url: String?, caption: String?) -> String? {
        if let caption = caption?.trimmingCharacters(in: .whitespacesAndNewlines), caption.isEmpty == false {
            return "\u{201C}\(caption)\u{201D}"
        }
        return shortLink(url)
    }

    /// `www.instagram.com/reel/C1abc/?igsh=x` → `instagram.com/reel/…`; a bare host stays bare.
    public static func shortLink(_ url: String?) -> String? {
        guard let url = url.flatMap(URL.init(string:)), let site = host(url.absoluteString) else { return nil }
        let steps = url.path().split(separator: "/").filter { $0.isEmpty == false }
        guard let first = steps.first else { return site }
        return steps.count == 1 ? "\(site)/\(first)" : "\(site)/\(first)/\u{2026}"
    }

    /// The host without its `www.`.
    static func host(_ url: String?) -> String? {
        guard let host = url.flatMap(URL.init(string:))?.host(), host.isEmpty == false else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}
