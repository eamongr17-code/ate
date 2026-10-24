import Foundation

/// **Which photos each dish can be shared on** (23 Oct, Eamon: a review of several dishes shares one
/// receipt per dish, on that dish's own photo). Read from `photo_dishes` (0081/0083), the same pairs
/// the photo viewer names.
public enum SharePhotoPairs {
    /// Each dish's photos as the entry's photo positions, in order: the photos paired with it. A dish
    /// with none has none. While no photo of the entry is paired with any dish (not matched yet, or the
    /// match failed), every dish offers every photo, so the person can still pick the right one.
    public static func positions(
        reviewIDs: [UUID], photos: [EntryCard.Photo], tags: [String: [PhotoDishTag]]
    ) -> [UUID: [Int]] {
        let ordered = photos.sorted { $0.position < $1.position }
        let known = Set(reviewIDs)
        let isPaired = ordered.contains { photo in
            tags[photo.url]?.contains { known.contains($0.reviewID) } == true
        }
        var positions: [UUID: [Int]] = [:]
        for id in reviewIDs {
            positions[id] = isPaired
                ? ordered.filter { tags[$0.url]?.contains { $0.reviewID == id } == true }.map(\.position)
                : ordered.map(\.position)
        }
        return positions
    }
}
