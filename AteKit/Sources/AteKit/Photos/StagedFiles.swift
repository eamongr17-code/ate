import Foundation

/// **The one lifecycle rule for a staged photo file** (round 4, after QA):
///
/// A file staged for an entry is deleted **only** when
/// (a) its upload is confirmed **and** the server's photo row for its entry exists at its position
///     (``StagedPhotoLedger/confirm(entryID:card:)``), or
/// (b) its entry is deleted or abandoned (``StagedPhotoLedger/abandon(entryID:)``).
///
/// Nothing is deleted eagerly as an upload returns, and nothing unrecorded is pruned while it is
/// young: a pick can be on disk a moment before anything has written its name down. A periodic
/// sweep (``sweep(_:keeping:olderThan:now:)``) takes unreferenced files older than a day.
///
/// Retries stay idempotent: an upload upserts on `(entry_id, position)`, and a file already
/// confirmed (so already gone) is skipped rather than failed (``StagedPhotoLedger/isConfirmed(_:)``).
public actor StagedPhotoLedger {
    public struct Record: Codable, Hashable, Sendable {
        public let entryID: UUID
        public let position: Int
        public let path: String
    }

    private var records: [Record]
    /// Paths already confirmed and removed — so a retry skips them. Bounded.
    private var confirmed: [String]
    private let storeURL: URL?

    public init(storeURL: URL?) {
        self.storeURL = storeURL
        let saved = storeURL.flatMap { try? Data(contentsOf: $0) }
            .flatMap { try? JSONDecoder().decode(Saved.self, from: $0) }
        self.records = saved?.records ?? []
        self.confirmed = saved?.confirmed ?? []
    }

    /// An entry will upload these files at these positions.
    public func record(entryID: UUID, photos: [QueuedPhoto]) {
        for photo in photos where records.contains(where: { $0.path == photo.path }) == false {
            records.append(Record(entryID: entryID, position: photo.position, path: photo.path))
        }
        persist()
    }

    /// The server's row for each position is the proof: a file goes only once its entry has a photo
    /// at its position. Returns the paths removed.
    @discardableResult
    public func confirm(entryID: UUID, card: EntryCard) -> [String] {
        let landed = Set(card.photos.map(\.position))
        let done = records.filter { $0.entryID == entryID && landed.contains($0.position) }
        guard done.isEmpty == false else { return [] }
        done.forEach { StagedFiles.remove($0.path) }
        records.removeAll { record in done.contains(record) }
        confirmed.append(contentsOf: done.map(\.path))
        if confirmed.count > Self.confirmedLimit { confirmed.removeFirst(confirmed.count - Self.confirmedLimit) }
        persist()
        return done.map(\.path)
    }

    /// The entry is gone (deleted, or its author's account): nothing will ever upload these.
    public func abandon(entryID: UUID) {
        let gone = records.filter { $0.entryID == entryID }
        gone.forEach { StagedFiles.remove($0.path) }
        records.removeAll { $0.entryID == entryID }
        persist()
    }

    /// A file already confirmed and removed: a retry skips it rather than failing on it.
    public func isConfirmed(_ path: String) -> Bool {
        confirmed.contains(path)
    }

    /// Every path still owed an upload — the sweep never touches these.
    public var recordedPaths: Set<String> { Set(records.map(\.path)) }

    private static let confirmedLimit = 500

    private struct Saved: Codable {
        var records: [Record]
        var confirmed: [String]
    }

    private func persist() {
        guard let storeURL,
              let data = try? JSONEncoder().encode(Saved(records: records, confirmed: confirmed)) else { return }
        try? data.write(to: storeURL, options: .atomic)
    }
}

/// The file operations behind the ledger.
public enum StagedFiles {
    /// A staged file, any `_t.jpg` beside it, and its draft folder if that leaves it empty.
    public static func remove(_ path: String) {
        let fileManager = FileManager.default
        let file = URL(filePath: path)
        try? fileManager.removeItem(at: file)
        try? fileManager.removeItem(atPath: file.deletingPathExtension().path() + PhotoAddress.thumbnailSuffix)
        removeIfEmpty(file.deletingLastPathComponent())
    }

    public static let sweepAge: TimeInterval = 24 * 60 * 60

    /// **The periodic sweep**: under `root` (the draft photo folders), every file that nothing
    /// references and that is older than `age` goes — a photo taken out before Done, a draft's
    /// leftovers. Young files are never touched: a pick can be on disk before its name is written
    /// anywhere. Returns the paths removed.
    @discardableResult
    public static func sweep(
        _ root: URL, keeping referenced: Set<String>, olderThan age: TimeInterval = sweepAge, now: Date = Date()
    ) -> [String] {
        let fileManager = FileManager.default
        let keep = Set(referenced.map { URL(filePath: $0).standardizedFileURL.path() })
        var removed: [String] = []
        guard let folders = try? fileManager.contentsOfDirectory(atPath: root.path()) else { return [] }
        for folder in folders {
            let directory = root.appending(path: folder, directoryHint: .isDirectory)
            guard let files = try? fileManager.contentsOfDirectory(atPath: directory.path()) else { continue }
            for name in files {
                let file = directory.appending(path: name)
                let path = file.standardizedFileURL.path()
                let attributes = try? fileManager.attributesOfItem(atPath: file.path())
                guard keep.contains(path) == false,
                      let modified = attributes?[.modificationDate] as? Date,
                      now.timeIntervalSince(modified) > age else { continue }
                try? fileManager.removeItem(at: file)
                removed.append(path)
            }
            removeIfEmpty(directory)
        }
        return removed
    }

    private static func removeIfEmpty(_ directory: URL) {
        let fileManager = FileManager.default
        // Only a draft's own folder (named for its id) — never a shared one a file was written into.
        guard UUID(uuidString: directory.lastPathComponent) != nil,
              let contents = try? fileManager.contentsOfDirectory(atPath: directory.path()),
              contents.isEmpty else { return }
        try? fileManager.removeItem(at: directory)
    }
}
