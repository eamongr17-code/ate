import Foundation
import Supabase

/// **The live edition reads** (round 8): `top_ate`, `because_you_loved`, `new_to_record`, the cravings
/// trio and `dishes_by_tag` in a city. Every read passes `p_city` only when there is one — everywhere
/// is the call without it, as `get_entry_feed` takes it.
public struct FeedEditionClient: FeedEditionReading {
    private let api: AteAPIClient

    public init(api: AteAPIClient) {
        self.api = api
    }

    public func topAte(city: String?, limit: Int) async throws -> [TopAteLine] {
        let data = try await rpc("top_ate", Self.cityParameters(city, limit: limit))
        return try Self.decodeTopAte(data)
    }

    public func becauseYouLoved(city: String?, limit: Int) async throws -> LovedShelf? {
        let data = try await rpc("because_you_loved", Self.cityParameters(city, limit: limit))
        return try Self.decodeLoved(data)
    }

    public func newToRecord(city: String?, since: Date, limit: Int) async throws -> [NewDish] {
        var parameters = Self.cityParameters(city, limit: limit)
        parameters["p_since"] = .string(PostgRESTTimestamp.string(from: since))
        let data = try await rpc("new_to_record", parameters)
        return try Self.decodeNew(data)
    }

    public func myCravings() async throws -> [Craving] {
        try Self.decodeCravings(try await rpc("my_cravings", [:]))
    }

    public func cravingOptions() async throws -> [CravingOption] {
        try Self.decodeOptions(try await rpc("craving_options", [:]))
    }

    public func setCravings(_ cravings: [Craving]) async throws -> [Craving] {
        try Self.decodeCravings(try await rpc("set_cravings", ["p_cravings": Self.cravingsParameter(cravings)]))
    }

    public func cravingDishes(_ craving: Craving, city: String?, limit: Int) async throws -> [FeedDish] {
        let limit = min(DishExploreClient.maximumPageSize, max(1, limit))
        let parameters = DishExploreClient.tagParameters(
            kind: craving.kind, slug: craving.slug, city: city, limit: limit
        )
        return try Self.decodeDishes(try await rpc("dishes_by_tag", parameters))
    }

    public func newToRecord(tag: Craving, city: String?, since: Date, limit: Int) async throws -> [NewDish] {
        var parameters = Self.cityParameters(city, limit: limit)
        parameters["p_since"] = .string(PostgRESTTimestamp.string(from: since))
        parameters.merge(Self.tagParameters(tag)) { _, tag in tag }
        return try Self.decodeNew(try await rpc("new_to_record", parameters))
    }

    public func latestReceipts(tag: Craving, city: String?, limit: Int) async throws -> [EntryCard] {
        var parameters: [String: AnyJSON] = [
            "p_page_size": .integer(min(EntryFeedClient.maximumPageSize, max(1, limit))),
            "p_include_own": .bool(false),
            "p_cursor_created_at": .null,
            "p_cursor_id": .null
        ]
        if let city { parameters["p_city"] = .string(city) }
        parameters.merge(Self.tagParameters(tag)) { _, tag in tag }
        let data = try await rpc("get_entry_feed", parameters)
        return try PostgRESTDate.decoder.decode([EntryCard].self, from: data)
    }

    private func rpc(_ name: String, _ parameters: [String: AnyJSON]) async throws -> Data {
        try await api.supabase.rpc(name, params: parameters).execute().data
    }

    // MARK: - Wire

    /// `p_city` (when there is one) and `p_limit`.
    static func cityParameters(_ city: String?, limit: Int) -> [String: AnyJSON] {
        var parameters: [String: AnyJSON] = ["p_limit": .integer(max(1, limit))]
        if let city { parameters["p_city"] = .string(city) }
        return parameters
    }

    /// A category page's filter: `p_kind` and `p_slug`, the slug passed back verbatim.
    static func tagParameters(_ tag: Craving) -> [String: AnyJSON] {
        ["p_kind": .string(tag.kind.rawValue), "p_slug": .string(tag.slug)]
    }

    /// `set_cravings`' `p_cravings`: the whole set, as `[{kind, slug}]`.
    static func cravingsParameter(_ cravings: [Craving]) -> AnyJSON {
        .array(cravings.map { .object(["kind": .string($0.kind.rawValue), "slug": .string($0.slug)]) })
    }

    /// Ranked 1…n and one line per dish, whatever order the rows arrive in.
    static func decodeTopAte(_ data: Data) throws -> [TopAteLine] {
        var seen: Set<UUID> = []
        return try PostgRESTDate.decoder.decode([TopAteLine].self, from: data)
            .sorted { $0.rank < $1.rank }
            .filter { seen.insert($0.dish.dishID).inserted }
    }

    static func decodeDishes(_ data: Data) throws -> [FeedDish] {
        var seen: Set<UUID> = []
        return try PostgRESTDate.decoder.decode([FeedDish].self, from: data).filter { seen.insert($0.dishID).inserted }
    }

    static func decodeNew(_ data: Data) throws -> [NewDish] {
        var seen: Set<UUID> = []
        return try PostgRESTDate.decoder.decode([LossyRow<NewDish>].self, from: data)
            .compactMap(\.value)
            .filter { seen.insert($0.dish.dishID).inserted }
    }

    /// `because_you_loved` (0055) is flat: `similar_dishes`-shaped rows with the anchor repeated on
    /// every one, read off the first. A wrapped `{anchor_dish_id, anchor_name, dishes}` also reads, so
    /// a reshaped function does not empty the shelf. No rows, or no anchor, is no shelf.
    static func decodeLoved(_ data: Data) throws -> LovedShelf? {
        if let rows = try? PostgRESTDate.decoder.decode([LovedRow].self, from: data) {
            guard let anchor = rows.first(where: { $0.anchorDishID != nil && $0.anchorName != nil }),
                  let anchorID = anchor.anchorDishID, let anchorName = anchor.anchorName else { return nil }
            let dishes = rows.compactMap(\.dish).filter { $0.dishID != anchorID }
            return shelf(anchorID: anchorID, name: anchorName, dishes: dishes)
        }
        let wrapped = try PostgRESTDate.decoder.decode(LovedWrapper.self, from: data)
        guard let anchorID = wrapped.anchorDishID, let anchorName = wrapped.anchorName else { return nil }
        return shelf(anchorID: anchorID, name: anchorName, dishes: wrapped.dishes.filter { $0.dishID != anchorID })
    }

    private static func shelf(anchorID: UUID, name: String, dishes: [FeedDish]) -> LovedShelf? {
        var seen: Set<UUID> = []
        let unique = dishes.filter { seen.insert($0.dishID).inserted }
        guard unique.isEmpty == false else { return nil }
        return LovedShelf(anchorDishID: anchorID, anchorName: name, dishes: unique)
    }

    /// A kind this build does not know is dropped, row by row.
    static func decodeCravings(_ data: Data) throws -> [Craving] {
        var seen: Set<String> = []
        return try JSONDecoder().decode([WireCraving].self, from: data)
            .compactMap(\.craving)
            .filter { seen.insert($0.id).inserted }
    }

    static func decodeOptions(_ data: Data) throws -> [CravingOption] {
        var seen: Set<String> = []
        return try JSONDecoder().decode([WireCraving].self, from: data)
            .compactMap { row -> CravingOption? in
                guard let craving = row.craving,
                      let group = row.group.flatMap(CravingOption.Group.init(rawValue:)) else { return nil }
                return CravingOption(craving: craving, group: group)
            }
            .filter { seen.insert($0.id).inserted }
    }

    private struct WireCraving: Decodable {
        let kind: String
        let slug: String
        let label: String
        let group: String?

        var craving: Craving? {
            DishTag.Kind(rawValue: kind).map { Craving(kind: $0, slug: slug, label: label) }
        }
    }

    private struct LovedRow: Decodable {
        let anchorDishID: UUID?
        let anchorName: String?
        let dish: FeedDish?

        enum CodingKeys: String, CodingKey {
            case anchorDishID = "anchor_dish_id"
            case anchorName = "anchor_name"
            case dishID = "dish_id"
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            anchorDishID = try container.decodeIfPresent(UUID.self, forKey: .anchorDishID)
            anchorName = try container.decodeIfPresent(String.self, forKey: .anchorName)
            dish = container.contains(.dishID) ? try FeedDish(from: decoder) : nil
        }
    }

    private struct LovedWrapper: Decodable {
        let anchorDishID: UUID?
        let anchorName: String?
        let dishes: [FeedDish]

        enum CodingKeys: String, CodingKey {
            case anchorDishID = "anchor_dish_id"
            case anchorName = "anchor_name"
            case dishes, rows
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            anchorDishID = try container.decodeIfPresent(UUID.self, forKey: .anchorDishID)
            anchorName = try container.decodeIfPresent(String.self, forKey: .anchorName)
            dishes = try container.decodeIfPresent([FeedDish].self, forKey: .dishes)
                ?? container.decodeIfPresent([FeedDish].self, forKey: .rows)
                ?? []
        }
    }
}

/// One row that may not decode — an unknown `kind` — without taking its neighbours down.
struct LossyRow<Value: Decodable>: Decodable {
    let value: Value?

    init(from decoder: any Decoder) throws {
        value = try? Value(from: decoder)
    }
}
