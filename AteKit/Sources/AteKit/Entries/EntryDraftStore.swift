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
    /// Whose draft this is — the signed-in user, read at the moment of every call.
    ///
    /// **A draft belongs to one person.** It lives under `<container>/<user id>/`, so signing out
    /// and signing in as somebody else can never resume, and post, the last person's unfinished
    /// words; theirs wait for them. With nobody signed in there is no draft at all. Nil (tests, the
    /// preview drive) keeps the single unowned file this store always had.
    public typealias Owner = @Sendable () -> UUID?

    private let root: URL
    private let photosRoot: URL
    private let owner: Owner?

    /// `FileManager` is not `Sendable`, so only the resolved URLs are kept. Every call reaches for
    /// `FileManager.default` at the moment it needs it, which is what the class is for anyway.
    private var fileManager: FileManager { .default }

    public init(containerName: String = "Entries", owner: Owner? = nil) {
        let fileManager = FileManager.default
        let support = (try? fileManager.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )) ?? URL.temporaryDirectory
        self.root = support.appending(path: containerName, directoryHint: .isDirectory)
        try? fileManager.createDirectory(at: root, withIntermediateDirectories: true)

        let caches = (try? fileManager.url(
            for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )) ?? URL.temporaryDirectory
        self.photosRoot = caches.appending(path: "\(containerName)Photos", directoryHint: .isDirectory)
        try? fileManager.createDirectory(at: photosRoot, withIntermediateDirectories: true)
        self.owner = owner
    }

    /// Where the current person's draft lives, or nil when there is nobody to own one.
    private var draftURL: URL? {
        guard let owner else { return root.appending(path: "draft.json", directoryHint: .notDirectory) }
        guard let id = owner() else { return nil }
        let folder = root.appending(path: id.uuidString.lowercased(), directoryHint: .isDirectory)
        try? fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appending(path: "draft.json", directoryHint: .notDirectory)
    }

    /// The current person's staged photos, or nil with nobody signed in.
    private var ownerPhotosRoot: URL? {
        guard let owner else { return photosRoot }
        guard let id = owner() else { return nil }
        return photosRoot.appending(path: id.uuidString.lowercased(), directoryHint: .isDirectory)
    }

    public func load() -> EntryDraft? {
        guard let draftURL,
              let data = try? Data(contentsOf: draftURL),
              let draft = try? JSONDecoder().decode(EntryDraft.self, from: data) else { return nil }
        guard draft.isExpired() == false else {
            clear(draftID: draft.id)
            return nil
        }
        return draft.hasContent ? draft : nil
    }

    public func save(_ draft: EntryDraft) {
        guard let draftURL else { return }
        var stamped = draft
        stamped.savedAt = Date()
        guard let data = try? JSONEncoder().encode(stamped) else { return }
        try? data.write(to: draftURL, options: .atomic)
    }

    public func clear(draftID: UUID?) {
        guard let draftURL else { return }
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
        let base = ownerPhotosRoot ?? URL.temporaryDirectory.appending(path: "AteUnowned", directoryHint: .isDirectory)
        let directory = base.appending(path: draftID.uuidString.lowercased(), directoryHint: .isDirectory)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    // MARK: - Owners

    /// Builds before drafts had owners wrote one unowned `draft.json`. It is handed to whoever is
    /// signed in at the first launch of this build — the person who wrote it — and never to anyone
    /// later: ``discardUnowned()`` runs on every sign-out.
    public func adoptUnownedDraft() {
        guard owner != nil, let draftURL else { return }
        let legacy = root.appending(path: "draft.json", directoryHint: .notDirectory)
        guard fileManager.fileExists(atPath: legacy.path(percentEncoded: false)) else { return }
        if fileManager.fileExists(atPath: draftURL.path(percentEncoded: false)) == false {
            try? fileManager.moveItem(at: legacy, to: draftURL)
        }
        try? fileManager.removeItem(at: legacy)
    }

    /// Removes any draft that has no owner. Safe to call at any time.
    public func discardUnowned() {
        guard owner != nil else { return }
        try? fileManager.removeItem(at: root.appending(path: "draft.json", directoryHint: .notDirectory))
    }

    /// Deletes one person's draft and staged photos outright — their account is gone.
    public func discardDrafts(of userID: UUID) {
        let folder = userID.uuidString.lowercased()
        try? fileManager.removeItem(at: root.appending(path: folder, directoryHint: .isDirectory))
        try? fileManager.removeItem(at: photosRoot.appending(path: folder, directoryHint: .isDirectory))
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
