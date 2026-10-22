import Foundation

/// One photo's dish (`photo_dishes.photo_url, review_id`, 0081): what the photo viewer names. A dish
/// may hold several photos; a photo names one dish.
struct PhotoDishRow: Decodable, Sendable, Hashable {
    let photoURL: String
    let reviewID: UUID

    enum CodingKeys: String, CodingKey {
        case photoURL = "photo_url"
        case reviewID = "review_id"
    }

    /// Photo URL → review id. Photos no dish holds have no row; the first read wins.
    static func map(from data: Data) throws -> [String: UUID] {
        let rows = try JSONDecoder().decode([PhotoDishRow].self, from: data)
        var out: [String: UUID] = [:]
        for row in rows where row.photoURL.isEmpty == false && out[row.photoURL] == nil {
            out[row.photoURL] = row.reviewID
        }
        return out
    }
}
