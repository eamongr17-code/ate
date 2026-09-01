import Foundation

/// A navigation *value* pointing at one dish — the thing pushed onto a `NavigationPath`.
///
/// It lives in AteKit, not in a feature folder, because every surface that can open a dish (feed,
/// search, diary, the post-log receipt) pushes the same value and only the destination is declared
/// once, at the navigation root. Routing by value is also why this carries a **UUID and never a
/// name**: the legacy build routed `/dish/:name` and inherited every name-collision bug in the
/// catalogue (`docs/backend/data-model.md` §0).
///
/// Construct it from ``FeedEntry/dishRoute`` (or ``Dish/canonicalDishID``) so a merged-away dish
/// resolves to its survivor rather than opening a tombstone.
public struct DishRoute: Hashable, Sendable, Codable {
    public let dishID: UUID

    public init(dishID: UUID) {
        self.dishID = dishID
    }
}
