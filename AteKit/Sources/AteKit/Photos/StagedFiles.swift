import Foundation

/// **The staged photo files, cleared as they stop being needed** (round 4).
///
/// Done keeps the draft's photo folder (the upload reads from it after the draft is gone), so the
/// files have to go some other way, or they stay on the phone forever:
/// - each file goes **the moment its upload lands** — the original and any `_t.jpg` beside it;
/// - what is still queued goes when the outbox **forgets** the entry (it was deleted, or its
///   author's account was);
/// - photos taken back out before Done go when the draft is finished (``prune(_:keeping:)``).
/// A folder left empty goes with its last file.
public enum StagedFiles {
    /// An upload landed: its file, its thumbnail if one was written, and the folder if now empty.
    public static func uploaded(_ path: String) {
        remove(path)
    }

    /// Nothing will ever upload these.
    public static func discard(_ paths: [String]) {
        paths.forEach(remove)
    }

    /// Everything in a draft's folder that is not one of `names` — a photo removed before Done.
    public static func prune(_ directory: URL, keeping names: Set<String>) {
        let fileManager = FileManager.default
        guard let contents = try? fileManager.contentsOfDirectory(atPath: directory.path()) else { return }
        for name in contents where names.contains(name) == false {
            try? fileManager.removeItem(at: directory.appending(path: name))
        }
        removeIfEmpty(directory)
    }

    private static func remove(_ path: String) {
        let fileManager = FileManager.default
        let file = URL(filePath: path)
        try? fileManager.removeItem(at: file)
        let thumbnail = file.deletingPathExtension().path() + PhotoAddress.thumbnailSuffix
        try? fileManager.removeItem(atPath: thumbnail)
        removeIfEmpty(file.deletingLastPathComponent())
    }

    private static func removeIfEmpty(_ directory: URL) {
        let fileManager = FileManager.default
        // Only a draft's own folder (named for its id) — never a shared one a file was written into.
        guard UUID(uuidString: directory.lastPathComponent) != nil else { return }
        guard let contents = try? fileManager.contentsOfDirectory(atPath: directory.path()),
              contents.isEmpty else { return }
        try? fileManager.removeItem(at: directory)
    }
}
