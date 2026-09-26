import CryptoKit
import Foundation

/// **Where a photo lives, and where its small copy lives.**
///
/// Every upload since round 3 lands a thumbnail beside the photo: `<path minus extension>_t.jpg`.
/// A squircle in a list asks for that first and falls back to the full image — old uploads have no
/// thumbnail, and a missing one is a 404 that must never become an empty tile.
///
/// Pure string work, so which URL a tile asks for is a test rather than a screenshot.
public enum PhotoAddress {
    /// What a thumbnail's name ends in.
    public static let thumbnailSuffix = "_t.jpg"

    /// The thumbnail beside a storage path: `u/e-0.jpg` → `u/e-0_t.jpg`. `nil` for a path that is
    /// already a thumbnail, or has no file name to put one beside.
    public static func thumbnailPath(for path: String) -> String? {
        guard path.isEmpty == false, path.hasSuffix(thumbnailSuffix) == false, path.hasSuffix("/") == false
        else { return nil }
        let fileStart = path.lastIndex(of: "/").map { path.index(after: $0) } ?? path.startIndex
        let file = path[fileStart...]
        guard file.isEmpty == false else { return nil }
        let stem = file.lastIndex(of: ".").map { file[..<$0] } ?? file
        guard stem.isEmpty == false else { return nil }
        return String(path[..<fileStart]) + stem + thumbnailSuffix
    }

    /// The same, for a public URL. Only a web photo has a thumbnail — a bundled fixture or a picked
    /// image is already on the phone. The query, if any, is kept: it belongs to the request, not
    /// to the file.
    public static func thumbnailURL(for url: URL) -> URL? {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let path = thumbnailPath(for: components.path) else { return nil }
        components.path = path
        return components.url
    }

    /// Every file a deleted entry leaves in storage: each photo, and each photo's thumbnail. Order
    /// kept, duplicates dropped — `storage.remove` is happy with a path that is not there, so an old
    /// upload with no thumbnail costs nothing.
    public static func withThumbnails(_ paths: [String]) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for path in paths {
            for candidate in [path, thumbnailPath(for: path)].compactMap({ $0 })
            where seen.insert(candidate).inserted {
                result.append(candidate)
            }
        }
        return result
    }

    /// A stable identity for a photo, from its address — so the same photo is the same view on every
    /// redraw. A fresh `UUID()` per draw is what made every image in the feed reload (and flicker)
    /// when one bookmark changed: the list re-rendered, every tile got a new id, and SwiftUI threw
    /// each one away with its loaded picture.
    public static func stableID(for address: String) -> UUID {
        var bytes = Array(SHA256.hash(data: Data(address.utf8)).prefix(16))
        // Version 5-shaped (name-based) and RFC 4122 variant, so it reads as a UUID anywhere.
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    /// The name a cached copy is filed under on disk: a hex digest, so any URL is a safe file name.
    public static func cacheKey(for address: String) -> String {
        SHA256.hash(data: Data(address.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// The photos to warm next: those of the `lookahead` entries after `index`, in the order they
    /// will scroll into view, at most `perEntry` from each — a slip draws three.
    public static func upcoming(
        in entries: [EntryCard],
        after index: Int,
        lookahead: Int = 6,
        perEntry: Int = 3
    ) -> [String] {
        guard index >= -1, lookahead > 0, perEntry > 0 else { return [] }
        let start = index + 1
        guard start < entries.count else { return [] }
        let end = min(entries.count, start + lookahead)
        return entries[start..<end].flatMap { entry in
            entry.photos.sorted { $0.position < $1.position }.prefix(perEntry).map(\.url)
        }
    }
}
