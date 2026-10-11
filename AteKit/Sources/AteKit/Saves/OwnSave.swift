import Foundation
import Supabase

/// **A dish you saved yourself** (0061, Eamon 11 Oct): a dish name at a real place, typed by hand or
/// read off a TikTok / Instagram post shared to Ate, and the link it came from. It is not a catalogue
/// dish — nobody on Ate has eaten it yet — so it has no dish id and never a score. Saves from Ate are
/// ``SavedDish``; the type a row is IS the distinction.
public struct OwnSave: Sendable, Hashable, Codable, Identifiable {
    public let id: UUID
    public let dishName: String
    public let restaurantID: UUID
    public let restaurantName: String
    public let restaurantCity: String?
    public let source: OwnSaveSource
    public let sourceURL: String?
    public let sourceAuthor: String?
    public let sourceCaption: String?
    public let createdAt: Date

    public init(
        id: UUID,
        dishName: String,
        restaurantID: UUID,
        restaurantName: String,
        restaurantCity: String? = nil,
        source: OwnSaveSource = .manual,
        sourceURL: String? = nil,
        sourceAuthor: String? = nil,
        sourceCaption: String? = nil,
        createdAt: Date
    ) {
        self.id = id
        self.dishName = dishName
        self.restaurantID = restaurantID
        self.restaurantName = restaurantName
        self.restaurantCity = restaurantCity
        self.source = source
        self.sourceURL = sourceURL
        self.sourceAuthor = sourceAuthor
        self.sourceCaption = sourceCaption
        self.createdAt = createdAt
    }

    enum CodingKeys: String, CodingKey {
        case id
        case dishName = "dish_name"
        case restaurantID = "restaurant_id"
        case restaurantName = "restaurant_name"
        case restaurantCity = "restaurant_city"
        case source
        case sourceURL = "source_url"
        case sourceAuthor = "source_author"
        case sourceCaption = "source_caption"
        case createdAt = "created_at"
    }
}

/// Where your own save came from. The wire values are 0061's CHECK.
public enum OwnSaveSource: String, Sendable, Hashable, Codable, CaseIterable {
    case manual
    case tiktok
    case instagram
    case link

    /// The source a link implies: TikTok and Instagram by their hosts (short links included), any
    /// other https link is a link, and no link is typed by hand. Not https → no link at all.
    public static func of(link: String?) -> OwnSaveSource {
        guard let url = OwnSaveDraft.httpsURL(link), let host = url.host()?.lowercased() else { return .manual }
        func on(_ domain: String) -> Bool { host == domain || host.hasSuffix("." + domain) }
        if on("tiktok.com") { return .tiktok }
        if on("instagram.com") || on("instagr.am") { return .instagram }
        return .link
    }
}

/// What a new own save is made from — the Add sheet's fields, or what the share card read.
public struct OwnSaveDraft: Sendable, Hashable {
    public var dishName: String
    public var restaurantID: UUID
    public var restaurantName: String
    public var link: String?
    public var author: String?
    public var caption: String?

    public init(
        dishName: String,
        restaurantID: UUID,
        restaurantName: String,
        link: String? = nil,
        author: String? = nil,
        caption: String? = nil
    ) {
        self.dishName = dishName
        self.restaurantID = restaurantID
        self.restaurantName = restaurantName
        self.link = link
        self.author = author
        self.caption = caption
    }

    /// The trimmed name, 1–120 characters (0061), else `nil`.
    public var trimmedDishName: String? {
        let name = dishName.trimmingCharacters(in: .whitespacesAndNewlines)
        return (1...120).contains(name.count) ? name : nil
    }

    /// The link as the server takes it: https, ≤ 2048, else none.
    public var cleanLink: String? {
        Self.httpsURL(link).map(\.absoluteString)
    }

    public var source: OwnSaveSource { .of(link: link) }

    static func httpsURL(_ text: String?) -> URL? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), text.isEmpty == false,
              text.count <= 2048, let url = URL(string: text),
              url.scheme?.lowercased() == "https", url.host()?.isEmpty == false else { return nil }
        return url
    }
}

/// The two writes and the one read (0061).
public protocol OwnSaving: Sendable {
    /// The caller's own saves, newest first (at most 500 exist).
    func ownSaves() async throws -> [OwnSave]
    /// Returns the new row's id.
    func add(_ draft: OwnSaveDraft) async throws -> UUID
    func remove(id: UUID) async throws
}

public struct OwnSaveClient: OwnSaving {
    let api: AteAPIClient

    static let columns = [
        "id", "dish_name", "restaurant_id", "restaurant_name", "restaurant_city",
        "source", "source_url", "source_author", "source_caption", "created_at"
    ].joined(separator: ",")

    public init(api: AteAPIClient) {
        self.api = api
    }

    public func ownSaves() async throws -> [OwnSave] {
        try await api.requireCurrentUserID()
        let data = try await api.supabase
            .from("my_own_saves")
            .select(Self.columns)
            .order("created_at", ascending: false)
            .order("id", ascending: false)
            .limit(500)
            .execute()
            .data
        return try PostgRESTDate.decoder.decode([OwnSave].self, from: data)
    }

    public func add(_ draft: OwnSaveDraft) async throws -> UUID {
        guard let name = draft.trimmedDishName else { throw OwnSaveError.invalidName }
        func text(_ value: String?) -> AnyJSON {
            guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), value.isEmpty == false else {
                return .null
            }
            return .string(value)
        }
        return try await api.rpc("add_own_save", parameters: [
            "p_dish_name": .string(name),
            "p_restaurant_id": .string(draft.restaurantID.uuidString.lowercased()),
            "p_source": .string(draft.source.rawValue),
            "p_source_url": draft.cleanLink.map { .string($0) } ?? .null,
            "p_source_author": text(draft.author),
            "p_source_caption": text(draft.caption)
        ], decoding: UUID.self)
    }

    public func remove(id: UUID) async throws {
        try await api.callRPC("remove_own_save", parameters: [
            "p_id": .string(id.uuidString.lowercased())
        ])
    }
}

public enum OwnSaveError: Error, Sendable {
    case invalidName
    /// The in-memory server, told to refuse.
    case refused
}
