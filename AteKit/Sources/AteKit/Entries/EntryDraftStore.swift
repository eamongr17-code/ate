import Foundation

/// The file-backed draft: one JSON file in Application Support, and one folder of staged JPEGs per
/// draft in Caches.
///
/// **Why the bytes are copied out of the picker.** A `PhotosPickerItem` identifier can only be
/// resolved back to an asset with photo-library authorization, which the picker itself does not need
/// — so storing identifiers would trade a permission prompt for a feature nobody asked for. Copying
/// the JPEG once, at pick time, costs a few hundred kilobytes and means the upload already has its
/// bytes when Done is tapped, even offline, even after a relaunch.
///
/// Photos live in Caches on purpose: if the system reclaims them the words still save, which is the
/// promise that actually matters (design rule 9).
public struct EntryDraftStore: EntryDraftStoring {
    private let draftURL: URL
    private let photosRoot: URL

    /// `FileManager` is not `Sendable`, so only the resolved URLs are kept. Every call reaches for
    /// `FileManager.default` at the moment it needs it, which is what the class is for anyway.
    private var fileManager: FileManager { .default }

    public init(containerName: String = "Entries") {
        let fileManager = FileManager.default
        let support = (try? fileManager.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )) ?? URL.temporaryDirectory
        let root = support.appending(path: containerName, directoryHint: .isDirectory)
        try? fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        self.draftURL = root.appending(path: "draft.json", directoryHint: .notDirectory)

        let caches = (try? fileManager.url(
            for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )) ?? URL.temporaryDirectory
        self.photosRoot = caches.appending(path: "\(containerName)Photos", directoryHint: .isDirectory)
        try? fileManager.createDirectory(at: photosRoot, withIntermediateDirectories: true)
    }

    public func load() -> EntryDraft? {
        guard let data = try? Data(contentsOf: draftURL),
              let draft = try? JSONDecoder().decode(EntryDraft.self, from: data) else { return nil }
        guard draft.isExpired() == false else {
            clear(draftID: draft.id)
            return nil
        }
        return draft.hasContent ? draft : nil
    }

    public func save(_ draft: EntryDraft) {
        var stamped = draft
        stamped.savedAt = Date()
        guard let data = try? JSONEncoder().encode(stamped) else { return }
        try? data.write(to: draftURL, options: .atomic)
    }

    public func clear(draftID: UUID?) {
        // Only clear a draft that is still the one being pointed at. A composer that finished long
        // ago must not delete the draft somebody started after it.
        if let draftID, let current = try? Data(contentsOf: draftURL),
           let draft = try? JSONDecoder().decode(EntryDraft.self, from: current), draft.id != draftID {
            return
        }
        try? fileManager.removeItem(at: draftURL)
        if let draftID {
            try? fileManager.removeItem(at: photoDirectory(for: draftID))
        }
    }

    public func photoDirectory(for draftID: UUID) -> URL {
        let directory = photosRoot.appending(
            path: draftID.uuidString.lowercased(), directoryHint: .isDirectory
        )
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

/// The test and preview seam: a draft held in memory, with the same clear-only-if-it-is-mine rule.
public final class InMemoryEntryDraftStore: EntryDraftStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var draft: EntryDraft?

    public init(draft: EntryDraft? = nil) {
        self.draft = draft
    }

    public func load() -> EntryDraft? {
        lock.withLock {
            guard let draft, draft.isExpired() == false, draft.hasContent else { return nil }
            return draft
        }
    }

    public func save(_ draft: EntryDraft) {
        lock.withLock {
            var stamped = draft
            stamped.savedAt = Date()
            self.draft = stamped
        }
    }

    public func clear(draftID: UUID?) {
        lock.withLock {
            if let draftID, let current = draft, current.id != draftID { return }
            draft = nil
        }
    }

    public func photoDirectory(for draftID: UUID) -> URL {
        URL.temporaryDirectory.appending(path: draftID.uuidString.lowercased(), directoryHint: .isDirectory)
    }
}
