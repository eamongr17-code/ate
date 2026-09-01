import Foundation

/// A navigation *value* pointing at one restaurant — the sibling of ``DishRoute``.
///
/// Same reasoning: every surface that can open a restaurant (search, a dish's header, the future
/// diary and receipt) pushes this value and the destination is declared once per stack. UUID only —
/// a restaurant name is a display string and two suburbs apart there are three "Hakata Gensuke".
public struct RestaurantRoute: Hashable, Sendable, Codable {
    public let restaurantID: UUID

    public init(restaurantID: UUID) {
        self.restaurantID = restaurantID
    }
}
