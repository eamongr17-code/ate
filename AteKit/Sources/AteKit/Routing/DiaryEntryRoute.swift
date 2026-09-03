import Foundation

/// A navigation *value* pointing at one of **your own** journal entries — the review, not the dish.
///
/// The diary's tap target is the entry, not the public dish page: the diary is a record of your
/// eating, and the dish page is everyone's. The two are one disclosure row apart (`DishRoute`), and
/// keeping them as separate route values is what stops the boundary blurring the way it did in the
/// legacy build.
///
/// Keyed on the **review id**, never a dish id: the same dish eaten twice is two entries, and only
/// the review identifies which one you tapped.
public struct DiaryEntryRoute: Hashable, Sendable, Codable {
    public let reviewID: UUID

    public init(reviewID: UUID) {
        self.reviewID = reviewID
    }
}
