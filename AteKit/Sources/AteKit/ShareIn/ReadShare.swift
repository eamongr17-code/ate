import Foundation
import Supabase

/// **What `read-share` made of a shared link** (`design/rebuild/share-to-ate.html`): where it came
/// from, the post's own words, and a *suggested* dish and place. Nothing here is saved — the share
/// card prefills its fields with it, and only the person's Save writes (`add_own_save`).
///
/// The place is never assumed (design rule 8): the server answers a place only when the caption
/// names exactly one, and one Google prediction still has to become a restaurants row through the
/// place sheet's own resolve path before Save can use it.
public struct ReadShareResult: Sendable, Hashable, Decodable {
    public let source: OwnSaveSource
    /// The canonical https link — what `source_url` stores.
    public let url: String
    public let author: String?
    public let caption: String?
    public let thumbnailURL: String?
    public let dish: String?
    /// The venue as the words name it — the place sheet's first query when no place came back.
    public let placeQuery: String?
    public let place: ReadSharePlace?

    public init(
        source: OwnSaveSource,
        url: String,
        author: String? = nil,
        caption: String? = nil,
        thumbnailURL: String? = nil,
        dish: String? = nil,
        placeQuery: String? = nil,
        place: ReadSharePlace? = nil
    ) {
        self.source = source
        self.url = url
        self.author = author
        self.caption = caption
        self.thumbnailURL = thumbnailURL
        self.dish = dish
        self.placeQuery = placeQuery
        self.place = place
    }

    enum CodingKeys: String, CodingKey {
        case source, url, author, caption, dish, place
        case thumbnailURL = "thumbnail_url"
        case placeQuery = "place_query"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let url = try container.decode(String.self, forKey: .url)
        // A source this build does not know yet is read off the link rather than failing the card.
        let rawSource = try container.decodeIfPresent(String.self, forKey: .source)
        self.source = rawSource.flatMap(OwnSaveSource.init(rawValue:)) ?? .of(link: url)
        self.url = url
        self.author = try container.decodeIfPresent(String.self, forKey: .author).trimmedOrNil
        self.caption = try container.decodeIfPresent(String.self, forKey: .caption).trimmedOrNil
        self.thumbnailURL = try container.decodeIfPresent(String.self, forKey: .thumbnailURL).trimmedOrNil
        self.dish = try container.decodeIfPresent(String.self, forKey: .dish).trimmedOrNil
        self.placeQuery = try container.decodeIfPresent(String.self, forKey: .placeQuery).trimmedOrNil
        self.place = try container.decodeIfPresent(ReadSharePlace.self, forKey: .place)
    }
}

/// The one place the caption named, matched against real places: a row we hold, or one Google
/// prediction still to be turned into a row.
public struct ReadSharePlace: Sendable, Hashable, Decodable {
    public let restaurantID: UUID?
    public let googlePlaceID: String?
    public let name: String
    /// The suburb or city under the name.
    public let locality: String?

    public init(restaurantID: UUID? = nil, googlePlaceID: String? = nil, name: String, locality: String? = nil) {
        self.restaurantID = restaurantID
        self.googlePlaceID = googlePlaceID
        self.name = name
        self.locality = locality
    }

    enum CodingKeys: String, CodingKey {
        case name, locality
        case restaurantID = "restaurant_id"
        case googlePlaceID = "google_place_id"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.restaurantID = try container.decodeIfPresent(String.self, forKey: .restaurantID)
            .flatMap(UUID.init(uuidString:))
        self.googlePlaceID = try container.decodeIfPresent(String.self, forKey: .googlePlaceID).trimmedOrNil
        self.name = try container.decode(String.self, forKey: .name)
        self.locality = try container.decodeIfPresent(String.self, forKey: .locality).trimmedOrNil
    }

    /// The prediction, as the place sheet would have offered it — so resolving it is the sheet's own
    /// pick path (`places-search?op=details`), never a second way to make a restaurant.
    public var suggestion: PlaceSuggestion? {
        if let restaurantID {
            return PlaceSuggestion(restaurantID: restaurantID, name: name, subtitle: locality)
        }
        guard let googlePlaceID else { return nil }
        return PlaceSuggestion(
            id: googlePlaceID, name: name, subtitle: locality, selection: .googlePlace(googlePlaceID)
        )
    }
}

/// Why a read came back with nothing.
public enum ReadShareError: Error, Sendable, Equatable {
    case notAuthenticated
    /// 422: not an https link the server will read.
    case badURL
    /// 429: thirty reads in ten minutes.
    case rateLimited
    case failed(status: Int)

    init(status: Int) {
        switch status {
        case 401: self = .notAuthenticated
        case 422: self = .badURL
        case 429: self = .rateLimited
        default: self = .failed(status: status)
        }
    }

    /// The `reason` a failed read is counted with.
    public var reason: String {
        switch self {
        case .notAuthenticated: "unauthorized"
        case .badURL: "bad_url"
        case .rateLimited: "rate_limited"
        case .failed: "error"
        }
    }
}

/// `read-share`, as the share card sees it. A protocol so the card's model runs against a fixture.
public protocol ReadSharing: Sendable {
    func read(url: URL, text: String?) async throws -> ReadShareResult
}

/// `POST /functions/v1/read-share` with the signed-in user's JWT.
public struct ReadShareClient: ReadSharing {
    private let api: AteAPIClient
    private let functionName = "read-share"
    /// The server gives each of its fetches and the model a few seconds; past this the card stops
    /// waiting and the fields are filled by hand.
    static let timeout: TimeInterval = 20

    public init(api: AteAPIClient) {
        self.api = api
    }

    public func read(url: URL, text: String?) async throws -> ReadShareResult {
        do {
            try await api.requireCurrentUserID()
        } catch {
            throw ReadShareError.notAuthenticated
        }
        do {
            return try await api.supabase.functions.invoke(
                functionName,
                options: FunctionInvokeOptions(
                    method: .post,
                    body: Body(url: url.absoluteString, text: text),
                    timeoutInterval: Self.timeout
                )
            ) { data, _ in try ReadShareResult.decode(data) }
        } catch FunctionsError.httpError(let code, _) {
            throw ReadShareError(status: code)
        }
    }

    private struct Body: Encodable, Sendable {
        let url: String
        let text: String?
    }
}

extension ReadShareResult {
    /// The 200 body. `ok` is not read: a body that decodes is the answer.
    public static func decode(_ data: Data) throws -> ReadShareResult {
        try JSONDecoder().decode(ReadShareResult.self, from: data)
    }
}

private extension Optional where Wrapped == String {
    /// Blank is absent.
    var trimmedOrNil: String? {
        guard let text = self?.trimmingCharacters(in: .whitespacesAndNewlines), text.isEmpty == false else {
            return nil
        }
        return text
    }
}
