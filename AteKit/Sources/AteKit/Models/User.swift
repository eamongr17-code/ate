import Foundation

/// A person (`public.profiles`, 1:1 with `auth.users`, data-model §1.1).
///
/// The table is `profiles`, not `users` — `auth.users` is Supabase's and holds email / provider
/// identity, which the client never reads. Everything here is public-readable to authenticated
/// users.
///
/// Counts are denormalised caches maintained by triggers; they are derived truth, rebuildable from
/// the edge tables (PV5-5). Never write them from the client.
public struct User: AteRecord, Hashable {
    public static let table = "profiles"
    public static let columns =
        "id,username,name,avatar_url,bio,created_at,deleted_at,follower_count,following_count,review_count"

    public let id: UUID
    /// Handle without `@`, case-insensitive server-side (citext). A display/lookup string —
    /// still never a join key.
    public let username: String
    public let name: String
    public let avatarURLString: String?
    public let bio: String?
    public let createdAt: Date
    /// Soft-delete tombstone (data-model §9.C). Accounts are never hard-deleted, so their reviews
    /// and comment threads survive.
    public let deletedAt: Date?
    public let followerCount: Int
    public let followingCount: Int
    public let reviewCount: Int

    public init(
        id: UUID,
        username: String,
        name: String,
        avatarURLString: String? = nil,
        bio: String? = nil,
        createdAt: Date,
        deletedAt: Date? = nil,
        followerCount: Int = 0,
        followingCount: Int = 0,
        reviewCount: Int = 0
    ) {
        self.id = id
        self.username = username
        self.name = name
        self.avatarURLString = avatarURLString
        self.bio = bio
        self.createdAt = createdAt
        self.deletedAt = deletedAt
        self.followerCount = followerCount
        self.followingCount = followingCount
        self.reviewCount = reviewCount
    }

    public var avatarURL: URL? { avatarURLString.flatMap(URL.init(string:)) }

    /// Soft-deleted: their content stays, but they are not a live account.
    public var isDeactivated: Bool { deletedAt != nil }

    /// `@handle`, for display only.
    public var handle: String { "@\(username)" }

    private enum CodingKeys: String, CodingKey {
        case id
        case username
        case name
        case avatarURLString = "avatar_url"
        case bio
        case createdAt = "created_at"
        case deletedAt = "deleted_at"
        case followerCount = "follower_count"
        case followingCount = "following_count"
        case reviewCount = "review_count"
    }
}
