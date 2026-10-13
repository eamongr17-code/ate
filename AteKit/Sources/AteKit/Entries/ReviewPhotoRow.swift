import Foundation

/// One dish line's own photo (`reviews.id, photo_url`, 0063): what the photo viewer names.
struct ReviewPhotoRow: Decodable, Sendable, Hashable {
    let id: UUID
    let photoURL: String?

    enum CodingKeys: String, CodingKey {
        case id
        case photoURL = "photo_url"
    }

    /// Photo URL → review id. Lines with no photo are left out; if two ever claim one photo (the
    /// server allows only one), the first read wins.
    static func map(from data: Data) throws -> [String: UUID] {
        let rows = try JSONDecoder().decode([ReviewPhotoRow].self, from: data)
        var out: [String: UUID] = [:]
        for row in rows {
            guard let url = row.photoURL, url.isEmpty == false, out[url] == nil else { continue }
            out[url] = row.id
        }
        return out
    }
}
