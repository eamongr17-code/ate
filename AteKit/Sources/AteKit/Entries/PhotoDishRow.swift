import CoreGraphics
import Foundation

/// Where a dish sits in a photo (0083): fractions of the image, 0 at the top-leading corner, 1 at
/// the bottom-trailing one. The photo matcher places it; a dish the author ticked by hand has none.
public struct PhotoDishBox: Sendable, Hashable, Codable {
    public let left: Double
    public let top: Double
    public let right: Double
    public let bottom: Double

    public init?(left: Double, top: Double, right: Double, bottom: Double) {
        guard left >= 0, top >= 0, right <= 1, bottom <= 1, left < right, top < bottom else { return nil }
        self.left = left
        self.top = top
        self.right = right
        self.bottom = bottom
    }

    /// `[left, top, right, bottom]`, as `dish_photos` sends it.
    public init?(_ values: [Double]) {
        guard values.count == 4 else { return nil }
        self.init(left: values[0], top: values[1], right: values[2], bottom: values[3])
    }

    public var centerX: Double { (left + right) / 2 }
    public var centerY: Double { (top + bottom) / 2 }
    public var width: Double { right - left }
    public var height: Double { bottom - top }
}

/// One dish in one photo (`photo_dishes`, 0081/0083): the line, and where it sits when it was placed.
public struct PhotoDishTag: Sendable, Hashable {
    public let reviewID: UUID
    public var box: PhotoDishBox?

    public init(reviewID: UUID, box: PhotoDishBox? = nil) {
        self.reviewID = reviewID
        self.box = box
    }
}

/// One photo's dish (`photo_dishes.photo_url, review_id, box_*`, 0081/0083): what the photo viewer
/// names. A dish may hold several photos, and a photo several dishes.
struct PhotoDishRow: Decodable, Sendable, Hashable {
    /// Only in a read of several entries at once.
    var entryID: UUID?
    let photoURL: String
    let reviewID: UUID
    var boxLeft: Double?
    var boxTop: Double?
    var boxRight: Double?
    var boxBottom: Double?

    enum CodingKeys: String, CodingKey {
        case entryID = "entry_id"
        case photoURL = "photo_url"
        case reviewID = "review_id"
        case boxLeft = "box_left"
        case boxTop = "box_top"
        case boxRight = "box_right"
        case boxBottom = "box_bottom"
    }

    var box: PhotoDishBox? {
        guard let boxLeft, let boxTop, let boxRight, let boxBottom else { return nil }
        return PhotoDishBox(left: boxLeft, top: boxTop, right: boxRight, bottom: boxBottom)
    }

    /// Photo URL → review id. Photos no dish holds have no row; the first read wins.
    static func map(from data: Data) throws -> [String: UUID] {
        try tags(from: data).mapValues { $0[0].reviewID }
    }

    /// Photo URL → every dish in it, in the order read, each once. Photos no dish holds are absent.
    static func tags(from data: Data) throws -> [String: [PhotoDishTag]] {
        tags(of: try JSONDecoder().decode([PhotoDishRow].self, from: data))
    }

    /// Entry → its photos' dishes, for a read of several entries. Entries with no row are absent.
    static func tagsByEntry(from data: Data) throws -> [UUID: [String: [PhotoDishTag]]] {
        let rows = try JSONDecoder().decode([PhotoDishRow].self, from: data)
        var byEntry: [UUID: [PhotoDishRow]] = [:]
        for row in rows {
            if let entryID = row.entryID { byEntry[entryID, default: []].append(row) }
        }
        return byEntry.mapValues(tags(of:)).filter { $0.value.isEmpty == false }
    }

    private static func tags(of rows: [PhotoDishRow]) -> [String: [PhotoDishTag]] {
        var out: [String: [PhotoDishTag]] = [:]
        for row in rows where row.photoURL.isEmpty == false {
            var tags = out[row.photoURL] ?? []
            guard tags.contains(where: { $0.reviewID == row.reviewID }) == false else { continue }
            tags.append(PhotoDishTag(reviewID: row.reviewID, box: row.box))
            out[row.photoURL] = tags
        }
        return out
    }
}

public extension PhotoDishTag {
    /// Whether an entry's pairs are worth one more match: none at all (posted before matching, or a
    /// match that failed), or several dishes and nothing placed (matched before 0083). The server
    /// answers each entry once (`unmatched_only`, photos_located_at), so asking again costs a no-op.
    static func wantsMatch(_ pairs: [String: [PhotoDishTag]]) -> Bool {
        guard pairs.isEmpty == false else { return true }
        let dishes = Set(pairs.values.flatMap { $0.map(\.reviewID) })
        return dishes.count > 1 && pairs.values.allSatisfy { $0.allSatisfy { $0.box == nil } }
    }
}

public extension PhotoDishBox {
    /// The part of an image of `imageSize` that shows this dish in a frame of `aspect` (width over
    /// height; 1 for a square tile), in the image's own units: the box with a little air, never
    /// zoomed past 3×, slid inside the picture rather than off its edge (a dish page's hero, 0083).
    func crop(imageSize: CGSize, aspect: CGFloat) -> CGRect {
        let width = imageSize.width, height = imageSize.height
        guard width > 0, height > 0, aspect > 0 else { return CGRect(origin: .zero, size: imageSize) }
        let air = 1.15
        let largest = min(width, height * aspect)
        let wanted = max(self.width * width * air, self.height * height * air * aspect)
        let cropWidth = min(largest, max(largest / 3, wanted))
        let cropHeight = cropWidth / aspect
        let midX = min(max(centerX * width, cropWidth / 2), width - cropWidth / 2)
        let midY = min(max(centerY * height, cropHeight / 2), height - cropHeight / 2)
        return CGRect(x: midX - cropWidth / 2, y: midY - cropHeight / 2, width: cropWidth, height: cropHeight)
    }
}
