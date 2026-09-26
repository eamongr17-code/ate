import Foundation

/// The account seam, in memory — `-ate-preview-data`, previews, and every test of the two models.
///
/// It is a real implementation and not a stub: it remembers the handle it was given, refuses one it
/// already holds, and actually removes a block. That is what lets Settings and the handle screen be
/// driven end to end on a simulator with no backend.
public final class InMemoryAccountService: AccountServing, @unchecked Sendable {
    /// Every handle the world has already got. The signed-in person's own is not in here — editing
    /// your handle and typing it back unchanged must not report it as taken.
    public private(set) var taken: Set<String>
    public private(set) var profile: AccountProfile
    public private(set) var blocked: [BlockedPerson]
    public private(set) var isDeleted = false
    /// The name Apple gave, if it was written.
    public private(set) var name: String?
    /// What `delete_account` answers. Set `authUserDeleted: false` to drive the half-deletion.
    public var deletion = AccountDeletion(ok: true, authUserDeleted: true)
    public private(set) var isSignedOut = false
    /// Every handle that was checked, in order — how the debounce is asserted.
    public private(set) var checked: [String] = []
    /// Set to throw from every call, to drive the failure paths.
    public var failure: (any Error)?

    private let lock = NSLock()

    public init(
        profile: AccountProfile = AccountProfile(id: UUID(), username: "eamon"),
        taken: Set<String> = ["ate", "taken"],
        blocked: [BlockedPerson] = []
    ) {
        self.profile = profile
        self.taken = taken
        self.blocked = blocked
    }

    public func isHandleAvailable(_ handle: String) async throws -> Bool {
        try check()
        return lock.withLock {
            checked.append(handle)
            return taken.contains(handle) == false
        }
    }

    /// Somebody else claims a handle — the race between the check and the write.
    public func take(_ handle: String) {
        lock.withLock { _ = taken.insert(handle) }
    }

    public func setHandle(_ handle: String) async throws {
        try check()
        // The unique index, in memory: somebody else's handle is refused the way Postgres refuses it.
        if lock.withLock({ taken.contains(handle) && handle != profile.username }) { throw HandleTaken() }
        lock.withLock {
            taken.remove(profile.username)
            profile = AccountProfile(id: profile.id, username: handle, avatarURL: profile.avatarURL)
        }
    }

    public func setName(_ name: String) async throws {
        try check()
        lock.withLock { self.name = name }
    }

    public func account() async throws -> AccountProfile {
        try check()
        return lock.withLock { profile }
    }

    @discardableResult
    public func setAvatar(_ image: AvatarUpload) async throws -> URL {
        try check()
        let url = URL(string: "https://example.invalid/avatars/\(profile.id.uuidString.lowercased()).jpg")!
        lock.withLock {
            profile = AccountProfile(id: profile.id, username: profile.username, avatarURL: url)
        }
        return url
    }

    public func blockedPeople(after cursor: PageCursor?, pageSize: Int) async throws -> Page<BlockedPerson> {
        try check()
        let all = lock.withLock { blocked }.sorted { one, other in
            (one.blockedAt, one.id.uuidString) > (other.blockedAt, other.id.uuidString)
        }
        let start = cursor.flatMap { cursor in
            all.firstIndex { $0.id == cursor.id }.map { $0 + 1 }
        } ?? 0
        let slice = Array(all[min(start, all.count)...].prefix(pageSize))
        return Page(items: slice, requestedLimit: pageSize)
    }

    public func unblock(userID: UUID) async throws {
        try check()
        lock.withLock { blocked.removeAll { $0.id == userID } }
    }

    public func deleteAccount() async throws -> AccountDeletion {
        try check()
        return lock.withLock {
            isDeleted = deletion.ok
            return deletion
        }
    }

    public func signOut() async throws {
        lock.withLock { isSignedOut = true }
    }

    private func check() throws {
        if let failure { throw failure }
    }
}
