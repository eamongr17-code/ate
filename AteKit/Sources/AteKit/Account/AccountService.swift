import Foundation
import Supabase

/// **Your own account** — the reads and writes behind `Handle.dc.html` and `Settings.dc.html`.
///
/// Its own seam rather than more methods on ``EntryService``: nothing here is about entries, and
/// every one of these calls is made at most once per session by one screen. Held as a protocol so
/// Settings can be driven with no backend at all.
public protocol AccountServing: Sendable {
    /// `handle_available(p_handle)`. **Not** a `profiles` select — the block-aware SELECT policy
    /// hides a blocked person's row, so a client-side lookup reports a taken handle as free and the
    /// write then fails its unique index (integration-design, Handle availability).
    func isHandleAvailable(_ handle: String) async throws -> Bool

    /// Writes `profiles.username`. The only column this path touches.
    func setHandle(_ handle: String) async throws

    /// Writes `profiles.name` — Apple's name for the person, on the one sign-in it is given.
    func setName(_ name: String) async throws

    /// The signed-in person as Settings shows them: handle, and the avatar if there is one.
    func account() async throws -> AccountProfile

    /// Uploads to `avatars/<uid>/…` and records the public URL on the profile. Returns the URL that
    /// was written, so the row on screen updates without a second read.
    @discardableResult
    func setAvatar(_ image: AvatarUpload) async throws -> URL

    /// The people you have blocked, newest first, keyset-paginated like every other list.
    func blockedPeople(after cursor: PageCursor?, pageSize: Int) async throws -> Page<BlockedPerson>

    /// `unblock_user(p_user_id)`. Both of you become visible to each other again.
    func unblock(userID: UUID) async throws

    /// **Deletes the account** (App Store 5.1.1(v); `delete_account`, 0032), in the contract's order:
    /// your own objects in `review-photos/<uid>/` and `avatars/<uid>/` first — a row delete does not
    /// free the bytes — then the RPC, which takes the auth user and everything that cascades from
    /// it. Never `deactivate_account`: that only tombstones, and the same Apple ID signs straight
    /// back into everything.
    func deleteAccount() async throws -> AccountDeletion

    /// Ends the session on this device.
    func signOut() async throws
}

/// What Settings knows about you.
public struct AccountProfile: Sendable, Hashable, Codable, Identifiable {
    public let id: UUID
    public let username: String
    public let avatarURL: URL?

    public init(id: UUID, username: String, avatarURL: URL? = nil) {
        self.id = id
        self.username = username
        self.avatarURL = avatarURL
    }
}

/// The bytes of a new avatar, already encoded by whoever picked it.
public struct AvatarUpload: Sendable, Hashable {
    public let data: Data
    public let contentType: String
    public let fileExtension: String

    public init(data: Data, contentType: String = "image/jpeg", fileExtension: String = "jpg") {
        self.data = data
        self.contentType = contentType
        self.fileExtension = fileExtension
    }
}

/// What `delete_account` answered.
///
/// `ok` means your data is gone. `authUserDeleted == false` means the **login survived** — the
/// definer could not delete `auth.users`, so the same Apple ID would sign into a fresh, empty
/// account. The data is still gone, but it is not the deletion that was asked for, and it has to be
/// reported rather than passed off as success.
public struct AccountDeletion: Sendable, Hashable, Decodable {
    public let ok: Bool
    public let authUserDeleted: Bool

    public init(ok: Bool, authUserDeleted: Bool) {
        self.ok = ok
        self.authUserDeleted = authUserDeleted
    }

    /// The whole of it: data and login.
    public var isComplete: Bool { ok && authUserDeleted }

    enum CodingKeys: String, CodingKey {
        case ok
        case authUserDeleted = "auth_user_deleted"
    }
}

/// One row of `Blocked people`, from `my_blocks` (0032) — a definer read, because the `profiles`
/// policy hides exactly these people from exactly this viewer and an embed would come back empty.
public struct BlockedPerson: Sendable, Hashable, Identifiable {
    public let id: UUID
    /// Nil only when the blocked account no longer exists (the join is a left join).
    public let username: String?
    public let name: String?
    public let avatarURL: URL?
    public let blockedAt: Date

    public init(id: UUID, username: String?, name: String? = nil, avatarURL: URL? = nil, blockedAt: Date) {
        self.id = id
        self.username = username
        self.name = name
        self.avatarURL = avatarURL
        self.blockedAt = blockedAt
    }

    /// What the row is titled. The handle — and, for an account that is gone, an honest label
    /// rather than an invented name.
    public var title: String {
        username.map(HandleName.display) ?? "Blocked account"
    }
}

extension BlockedPerson: AteRecord {
    /// An RPC, not a table (`my_blocks`, 0032) — named so the record says where it comes from.
    public static var table: String { "my_blocks" }
    public static var columns: String { "blocked_id,username,name,avatar_url,created_at" }
    public static var primaryKeyColumn: String { "blocked_id" }

    enum CodingKeys: String, CodingKey {
        case id = "blocked_id"
        case username, name
        case avatarURL = "avatar_url"
        case blockedAt = "created_at"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(UUID.self, forKey: .id),
            username: try container.decodeIfPresent(String.self, forKey: .username),
            name: try container.decodeIfPresent(String.self, forKey: .name),
            avatarURL: try container.decodeIfPresent(String.self, forKey: .avatarURL).flatMap(URL.init(string:)),
            blockedAt: try container.decode(Date.self, forKey: .blockedAt)
        )
    }
}

extension BlockedPerson: KeysetPaginated {
    public var pageCursor: PageCursor { PageCursor(createdAt: blockedAt, id: id) }
}

/// Supabase.
public struct AccountClient: AccountServing {
    /// Blocks are a handful of rows for one person; the page size is small on purpose.
    public static let defaultPageSize = 30

    private let api: AteAPIClient

    public init(api: AteAPIClient) {
        self.api = api
    }

    public func isHandleAvailable(_ handle: String) async throws -> Bool {
        try await api.rpc("handle_available", parameters: ["p_handle": .string(handle)])
    }

    /// Throws ``HandleTaken`` when the unique index refused — somebody took it between the check
    /// and the write. Every other failure is passed through as it came: it is not a verdict on the
    /// handle, and the screen must not say it is.
    public func setHandle(_ handle: String) async throws {
        do {
            try await updateProfile(["username": handle])
        } catch let error as PostgrestError where error.code == "23505" {
            throw HandleTaken()
        }
    }

    public func setName(_ name: String) async throws {
        try await updateProfile(["name": name])
    }

    private func updateProfile(_ values: [String: String]) async throws {
        let id = try await api.requireCurrentUserID()
        _ = try await api.supabase
            .from("profiles")
            .update(values, returning: .minimal)
            .eq("id", value: id.uuidString.lowercased())
            .execute()
    }

    public func account() async throws -> AccountProfile {
        let id = try await api.requireCurrentUserID()
        let rows: [AccountRow] = try await api.supabase
            .from("profiles")
            .select("id,username,avatar_url")
            .eq("id", value: id.uuidString.lowercased())
            .limit(1)
            .execute()
            .value
        guard let row = rows.first else { throw AteAPIError.notFound(table: "profiles", id: id) }
        return AccountProfile(
            id: row.id,
            username: row.username,
            avatarURL: row.avatarURL.flatMap(URL.init(string:))
        )
    }

    @discardableResult
    public func setAvatar(_ image: AvatarUpload) async throws -> URL {
        let id = try await api.requireCurrentUserID()
        // `avatars/<auth.uid()>/…` is what 0007's insert policy checks; a path outside it is a
        // 42501, not a 404. Deterministic and upserted, so a retried upload overwrites rather
        // than leaving the bucket full of half-finished avatars.
        let path = "\(id.uuidString.lowercased())/avatar.\(image.fileExtension)"
        let storage = api.supabase.storage.from("avatars")
        _ = try await storage.upload(
            path,
            data: image.data,
            options: FileOptions(contentType: image.contentType, upsert: true)
        )
        // The object URL is durable and the bucket is public, so the row stores the URL and not the
        // bytes. A cache-buster is appended because the path never changes: without it the old
        // avatar would keep being served from every CDN and `AsyncImage` cache that has it.
        let base = try storage.getPublicURL(path: path).absoluteString
        let url = base + "?v=\(Int(Date().timeIntervalSince1970))"
        _ = try await api.supabase
            .from("profiles")
            .update(["avatar_url": url], returning: .minimal)
            .eq("id", value: id.uuidString.lowercased())
            .execute()
        guard let resolved = URL(string: url) else { throw AteAPIError.notFound(table: "avatars", id: id) }
        return resolved
    }

    public func blockedPeople(after cursor: PageCursor?, pageSize: Int) async throws -> Page<BlockedPerson> {
        try await api.requireCurrentUserID()
        let limit = min(PageRequest.maximumLimit, max(1, pageSize))
        var parameters: [String: AnyJSON] = ["p_limit": .integer(limit)]
        if let cursor {
            parameters["p_cursor_created_at"] = .string(PostgRESTTimestamp.string(from: cursor.createdAt))
            parameters["p_cursor_blocked_id"] = .string(cursor.id.uuidString.lowercased())
        }
        let data = try await api.supabase.rpc("my_blocks", params: parameters).execute().data
        let rows = try PostgRESTDate.decoder.decode([BlockedPerson].self, from: data)
        return Page(items: rows, requestedLimit: limit)
    }

    public func unblock(userID: UUID) async throws {
        try await api.callRPC("unblock_user", parameters: [
            "p_user_id": .string(userID.uuidString.lowercased())
        ])
    }

    public func deleteAccount() async throws -> AccountDeletion {
        let folder = try await api.requireCurrentUserID().uuidString.lowercased()
        for bucket in Self.personalBuckets {
            try await purge(bucket: bucket, folder: folder)
        }
        return try await api.rpc("delete_account")
    }

    public func signOut() async throws {
        try await api.supabase.auth.signOut()
    }

    /// The two buckets whose objects are yours, each under a folder named for your id (0007).
    static let personalBuckets = ["review-photos", "avatars"]

    /// Empties `<bucket>/<folder>/`, a page at a time. Both buckets are flat under the folder
    /// (`<uid>/<entry>-<n>.jpg`, `<uid>/avatar.jpg`), so one level is all there is. Bounded, so a
    /// list that somehow never shrinks cannot hold a deletion open forever.
    private func purge(bucket: String, folder: String) async throws {
        let storage = api.supabase.storage.from(bucket)
        for _ in 0..<Self.maximumPurgePages {
            let listed = try await storage.list(path: folder, options: SearchOptions(limit: Self.purgePageSize))
            let paths = listed.filter { $0.id != nil }.map { "\(folder)/\($0.name)" }
            guard paths.isEmpty == false else { return }
            let removed = try await storage.remove(paths: paths)
            guard removed.isEmpty == false else { return }
        }
    }

    private static let purgePageSize = 100
    private static let maximumPurgePages = 100

    private struct AccountRow: Decodable, Sendable {
        let id: UUID
        let username: String
        let avatarURL: String?

        enum CodingKeys: String, CodingKey {
            case id, username
            case avatarURL = "avatar_url"
        }
    }
}
