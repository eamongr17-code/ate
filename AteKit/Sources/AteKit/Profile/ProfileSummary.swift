import Foundation

/// **Someone's profile header**, exactly as `profile_summary(p_user_id)` returns it.
///
/// Viewer-relative by construction: the RPC is `security invoker`, so a stranger's counts are
/// computed over the entries that stranger can actually see. `isMe` comes from the server rather
/// than from comparing ids on the client, so there is one answer to "is this my profile".
public struct ProfileSummary: Sendable, Hashable, Codable, Identifiable {
    public let userID: UUID
    public let username: String
    public let name: String?
    public let avatarURL: String?
    public let bio: String?
    public let city: String?
    public let createdAt: Date?
    /// Entries written.
    public let orders: Int
    /// Distinct places visited.
    public let places: Int
    /// Receipt line items — the north-star unit (PRODUCT.md).
    public let dishes: Int
    public let scored: Int
    public let avgScore: Double?
    public let isMe: Bool

    public var id: UUID { userID }

    public init(
        userID: UUID,
        username: String,
        name: String? = nil,
        avatarURL: String? = nil,
        bio: String? = nil,
        city: String? = nil,
        createdAt: Date? = nil,
        orders: Int = 0,
        places: Int = 0,
        dishes: Int = 0,
        scored: Int = 0,
        avgScore: Double? = nil,
        isMe: Bool = false
    ) {
        self.userID = userID
        self.username = username
        self.name = name
        self.avatarURL = avatarURL
        self.bio = bio
        self.city = city
        self.createdAt = createdAt
        self.orders = orders
        self.places = places
        self.dishes = dishes
        self.scored = scored
        self.avgScore = avgScore
        self.isMe = isMe
    }

    enum CodingKeys: String, CodingKey {
        case username, name, bio, city, orders, places, dishes, scored
        case userID = "user_id"
        case avatarURL = "avatar_url"
        case createdAt = "created_at"
        case avgScore = "avg_score"
        case isMe = "is_me"
    }
}
