import Foundation

/// **Which photos each dish can be shared on** (23 Oct, Eamon: a review of several dishes shares one
/// receipt per dish, on that dish's own photo). Read from `photo_dishes` (0081/0083), the same pairs
/// the photo viewer names.
public enum SharePhotoPairs {
    /// Each dish's photos as the entry's photo positions, in order: the photos paired with it. A dish
    /// with none has none — and so does every dish while nothing is paired (not matched yet, or the
    /// match failed or was skipped). A photo is never put under a dish it was not matched to: one
    /// photo on a review of three went on all three dish receipts until the match landed (26 Oct,
    /// Eamon). The whole receipt still goes on any photo.
    public static func positions(
        reviewIDs: [UUID], photos: [EntryCard.Photo], tags: [String: [PhotoDishTag]]
    ) -> [UUID: [Int]] {
        let ordered = photos.sorted { $0.position < $1.position }
        var positions: [UUID: [Int]] = [:]
        for id in reviewIDs {
            positions[id] = ordered.filter { tags[$0.url]?.contains { $0.reviewID == id } == true }.map(\.position)
        }
        return positions
    }
}
