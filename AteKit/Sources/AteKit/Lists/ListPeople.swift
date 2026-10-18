import Foundation

/// **A person on a list** (0073) — its owner, or someone invited to it. `list_people` names the id
/// `user_id`; `get_list` and `my_lists` name it `id`.
public struct ListPerson: Sendable, Hashable, Identifiable, Decodable {
    public enum Status: String, Sendable, Hashable, Decodable {
        case invited
        case accepted
    }

    public let id: UUID
    public let username: String
    public let avatarURL: String?
    /// The owner reads as accepted.
    public let status: Status

    public init(id: UUID, username: String, avatarURL: String? = nil, status: Status = .accepted) {
        self.id = id
        self.username = username
        self.avatarURL = avatarURL
        self.status = status
    }

    enum CodingKeys: String, CodingKey {
        case id, username, status
        case userID = "user_id"
        case avatarURL = "avatar_url"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decodeIfPresent(UUID.self, forKey: .userID) ?? container.decode(UUID.self, forKey: .id),
            username: try container.decodeIfPresent(String.self, forKey: .username) ?? "",
            avatarURL: try container.decodeIfPresent(String.self, forKey: .avatarURL),
            status: (try? container.decodeIfPresent(Status.self, forKey: .status)) ?? .accepted
        )
    }
}

/// **An invitation to someone else's list** — `my_list_invites` (0073), the Notifications page's
/// "List invites".
public struct ListInvite: Sendable, Hashable, Identifiable, Decodable {
    public let listID: UUID
    public let name: String
    public let itemCount: Int
    public let covers: [String]
    public let coverURL: String?
    public let owner: ListPerson
    public let invitedAt: Date

    public init(
        listID: UUID, name: String, itemCount: Int, covers: [String] = [], coverURL: String? = nil,
        owner: ListPerson, invitedAt: Date
    ) {
        self.listID = listID
        self.name = name
        self.itemCount = max(0, itemCount)
        self.covers = Array(covers.prefix(UserList.coverLimit))
        self.coverURL = coverURL
        self.owner = owner
        self.invitedAt = invitedAt
    }

    enum CodingKeys: String, CodingKey {
        case name, covers, owner
        case listID = "list_id"
        case itemCount = "item_count"
        case coverURL = "cover_url"
        case invitedAt = "invited_at"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            listID: try container.decode(UUID.self, forKey: .listID),
            name: try container.decode(String.self, forKey: .name),
            itemCount: try container.decodeIfPresent(Int.self, forKey: .itemCount) ?? 0,
            covers: (try? container.decodeIfPresent([String].self, forKey: .covers)) ?? [],
            coverURL: try container.decodeIfPresent(String.self, forKey: .coverURL),
            owner: try container.decode(ListPerson.self, forKey: .owner),
            invitedAt: try container.decode(Date.self, forKey: .invitedAt)
        )
    }

    public var id: UUID { listID }

    /// The list as it will sit on your shelf once accepted.
    public func summary(acceptedAt: Date) -> UserList {
        UserList(
            id: listID, name: name, itemCount: itemCount, covers: covers, createdAt: invitedAt, updatedAt: invitedAt,
            coverURL: coverURL, isOwn: false, owner: owner, shelvedAt: acceptedAt
        )
    }
}

/// **What the cover sheet chose** (0073).
public enum ListCoverChoice: Sendable, Hashable {
    /// The mosaic of the first four photos (or the first photo) — nothing picked.
    case automatic
    /// One of the list's own dish photos, by item.
    case item(UUID)
    /// A photo from the library, squared and compressed on the phone.
    case upload(AvatarUpload)

    /// The item a dish pick names.
    public var itemID: UUID? {
        if case let .item(id) = self { return id }
        return nil
    }
}
