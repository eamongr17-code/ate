import Foundation
import Testing

@testable import AteKit

/// The ported dish-dedup suite.
///
/// **Port note.** The legacy TypeScript module and its Jest cases are not recoverable from this
/// repo (the reboot commit carried over only `supabase/`), so these cases are translated from the
/// behaviour the legacy client was written against and the spec restates: `dishes_identity_uq` on
/// `(restaurant_id, lower(name)) WHERE merged_into_dish_id IS NULL` (migration 0002), §11.4's
/// "no case-insensitively-equal name exists here" gate, and §6.3's "a collision resolves to the
/// existing row, never an error".
@Suite("Dish dedup + name key")
struct DishDedupTests {
    private let restaurantID = UUID()
    private let other = UUID()

    private func dish(_ name: String, restaurantID: UUID? = nil, mergedInto: UUID? = nil) -> Dish {
        Dish(
            id: UUID(),
            name: name,
            restaurantID: restaurantID ?? self.restaurantID,
            mergedIntoDishID: mergedInto,
            createdAt: Date(timeIntervalSince1970: 0)
        )
    }

    // MARK: - Normalisation

    @Test("the key is case-insensitive, matching lower(name) in dishes_identity_uq", arguments: [
        ("Brisket", "brisket"),
        ("BRISKET", "Brisket"),
        ("pad thai", "Pad Thai")
    ])
    func caseInsensitive(lhs: String, rhs: String) {
        #expect(DishNameKey(lhs) == DishNameKey(rhs))
    }

    @Test("the key trims and collapses whitespace — deliberately looser than lower(name)", arguments: [
        ("  Brisket ", "Brisket"),
        ("Pad  Thai", "Pad Thai"),
        ("Pad\tThai", "Pad Thai"),
        ("Pad\nThai", "Pad Thai")
    ])
    func whitespaceFolding(lhs: String, rhs: String) {
        #expect(DishNameKey(lhs) == DishNameKey(rhs))
    }

    @Test("distinct dishes stay distinct — no punctuation or diacritic folding")
    func doesNotOverFold() {
        #expect(DishNameKey("Marg's Diner") != DishNameKey("Margs Diner"))
        #expect(DishNameKey("Creme Brulee") != DishNameKey("Crème Brûlée"))
        #expect(DishNameKey("Brisket") != DishNameKey("Brisket Roll"))
    }

    @Test("a whitespace-only name is empty and can never match or be created")
    func emptyKey() {
        #expect(DishNameKey("   ").isEmpty)
        #expect(DishDedup.match(name: "  ", in: [dish("")]) == nil)
        #expect(DishDedup.shouldOfferCreate(query: "   ", in: []) == false)
    }

    // MARK: - Matching

    @Test("an existing dish is found case- and space-insensitively")
    func matchesExisting() {
        let brisket = dish("Brisket")
        #expect(DishDedup.match(name: "brisket", in: [brisket])?.id == brisket.id)
        #expect(DishDedup.match(name: " BRISKET  ", in: [brisket])?.id == brisket.id)
    }

    @Test("a merged-away dish never matches — the unique index excludes tombstones")
    func tombstonesAreInvisible() {
        let survivor = dish("Brisket")
        let tombstone = dish("Brisket", mergedInto: survivor.id)
        #expect(DishDedup.match(name: "Brisket", in: [tombstone]) == nil)
        // With both present the LIVE row wins regardless of order.
        #expect(DishDedup.match(name: "Brisket", in: [tombstone, survivor])?.id == survivor.id)
    }

    // MARK: - The create gate (§11.4)

    @Test("create is offered only at 2+ characters", arguments: [
        ("", false), ("b", false), (" b ", false), ("br", true), ("brisket", true)
    ])
    func minimumLength(query: String, offered: Bool) {
        #expect(DishDedup.shouldOfferCreate(query: query, in: []) == offered)
    }

    @Test("create is NOT offered when the name already exists here (search-existing-first)")
    func suppressedByExistingName() {
        let menu = [dish("Brisket"), dish("Mac and Cheese")]
        #expect(DishDedup.shouldOfferCreate(query: "brisket", in: menu) == false)
        #expect(DishDedup.shouldOfferCreate(query: "  Brisket ", in: menu) == false)
    }

    @Test("create IS offered for a near-duplicate — merging is a server concern, not a client block")
    func nearDuplicatesAreNotBlocked() {
        let menu = [dish("Brisket")]
        #expect(DishDedup.shouldOfferCreate(query: "Brisket Roll", in: menu))
        #expect(DishDedup.shouldOfferCreate(query: "Brisketh", in: menu))
    }

    @Test("create is offered again once the only match is a tombstone")
    func tombstoneDoesNotSuppressCreate() {
        let menu = [dish("Brisket", mergedInto: UUID())]
        #expect(DishDedup.shouldOfferCreate(query: "Brisket", in: menu))
    }

    @Test("the names-only gate is the same rule — the view checks the rows it already rendered")
    func nameGateMatchesDishGate() {
        let menu = [dish("Brisket"), dish("Mac and Cheese")]
        let names = menu.map(\.name)
        for query in ["b", "br", "brisket", "  BRISKET ", "Brisket Roll", "mac and cheese"] {
            #expect(
                DishDedup.shouldOfferCreate(query: query, existingNames: names)
                    == DishDedup.shouldOfferCreate(query: query, in: menu),
                "diverged on '\(query)'"
            )
        }
    }

    @Test("isSameName is the same rule, reusable by the resolve-or-create path")
    func sameName() {
        #expect(DishDedup.isSameName("Pad  Thai", "pad thai"))
        #expect(DishDedup.isSameName("Pad Thai", "Pad Thai Special") == false)
        #expect(DishDedup.isSameName("", "") == false)
    }
}
