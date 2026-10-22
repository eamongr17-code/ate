import Foundation

/// **The last first page a list showed, kept on the phone** — so a cold open draws the Journal (and
/// the Feed) at once from what was there last time, and the read that follows only refreshes it.
///
/// One file per list and per person (`Caches/ate-pages/<list>-<user>.json`), so the next person to
/// sign in on the phone never reads someone else's. It is a cache in the strict sense: the system
/// may clear it, a file that will not decode is ignored, and nothing is ever written back to the
/// server from it. A page drawn from it is the list's stand-in until its own first read lands.
public struct EntryPageCache: Sendable {
    let file: URL

    /// `nil` without a person to file it under — a signed-out reader keeps nothing.
    public init?(list: String, owner: UUID?, directory: URL? = nil) {
        guard let owner else { return nil }
        let folder = directory ?? Self.defaultDirectory
        file = folder.appendingPathComponent("\(list)-\(owner.uuidString.lowercased()).json")
    }

    /// What the list last showed, or `nil` when there is nothing readable. Small (one page), so it
    /// is read in line: the first frame is the point.
    public func read() -> [EntryCard]? {
        guard let data = try? Data(contentsOf: file), data.isEmpty == false else { return nil }
        return try? JSONDecoder().decode([EntryCard].self, from: data)
    }

    /// Keeps the rows, off the main thread, one write at a time so a later page is never
    /// overwritten by an earlier one finishing late.
    public func write(_ cards: [EntryCard]) {
        let file = file
        Self.queue.async {
            guard let data = try? JSONEncoder().encode(cards) else { return }
            try? FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try? data.write(to: file, options: .atomic)
        }
    }

    /// Every list's file, for everybody — a session ending leaves nothing of it on the phone.
    public static func clearAll(directory: URL? = nil) {
        let folder = directory ?? defaultDirectory
        queue.async { try? FileManager.default.removeItem(at: folder) }
    }

    /// Waits for the writes already asked for. Tests only.
    static func flush() {
        queue.sync {}
    }

    static var defaultDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ate-pages", isDirectory: true)
    }

    /// One write at a time. The file is the plain `JSONEncoder`/`JSONDecoder` pair's, so a date goes
    /// out and comes back exactly — unlike a round trip through the wire's text.
    private static let queue = DispatchQueue(label: "ate.entry-page-cache", qos: .utility)
}
