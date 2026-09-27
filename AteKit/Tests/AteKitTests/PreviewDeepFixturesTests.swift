import Foundation
import Testing

@testable import AteKit

/// `-ate-preview-deep`: the long lists the responsiveness drives scroll to mid-list — Jess's
/// profile, Tipo 00 and its prawn spaghetti — without moving anything the artboards draw.
@Suite("Preview deep fixtures")
struct PreviewDeepFixturesTests {

    private static let birthday = "E0000000-0000-4000-8000-000000000001"

    @Test("off unless a UI-test run asks for it by name")
    func gated() {
        #expect(PreviewFaults.deepFixtures == false)
    }

    @Test("sixteen of Jess's visits to Tipo 00 and eight to the pasta bar, older than every seeded entry")
    func older() throws {
        let deep = InMemorySocialService.deepEntries
        let oldestSeed = try #require(InMemorySocialService.seededEntries.map(\.createdAt).min())
        #expect(deep.count == 24)
        #expect(deep.allSatisfy { $0.authorID == InMemorySocialService.Seed.jess })
        #expect(deep.filter { $0.place?.id == InMemorySocialService.Seed.tipo.id }.count == 16)
        #expect(deep.filter { $0.place?.id == InMemorySocialService.Seed.pastaio.id }.count == 8)
        #expect(deep.allSatisfy { $0.createdAt < oldestSeed })
        #expect(Set(deep.map(\.id)).count == deep.count)
    }

    @Test("their lines are the birthday visit's two dishes, not new ones with the same names")
    func sameDishes() async throws {
        let birthday = try #require(InMemorySocialService.seededEntries.first { $0.id.uuidString == Self.birthday })
        let prawn = try #require(birthday.items.first { $0.dishName == "Prawn spaghetti" }).dishID
        let tiramisu = try #require(birthday.items.first { $0.dishName == "Tiramisu" }).dishID
        let lines = InMemorySocialService.deepEntries.flatMap(\.items)
        #expect(lines.filter { $0.dishName == "Prawn spaghetti" }.allSatisfy { $0.dishID == prawn })
        #expect(lines.filter { $0.dishName == "Tiramisu" }.allSatisfy { $0.dishID == tiramisu })

        let social = InMemorySocialService(
            entries: InMemorySocialService.seededEntries + InMemorySocialService.deepEntries
        )
        let reviews = try await social.dishReviews(dishID: prawn, after: nil, pageSize: 50)
        #expect(reviews.items.count == 17)
    }

    @Test("the specials make a dish search for \"ni\" long enough to scroll, and a 4.0 filter shorter")
    func specials() async throws {
        let social = InMemorySocialService(
            entries: InMemorySocialService.seededEntries + InMemorySocialService.deepEntries
        )
        let all = try await social.dishes(query: "ni", after: nil, pageSize: 50).rows
        let filtered = try await social.dishes(
            query: "ni", filters: SearchFilters(minimumScore: 4.0), after: nil, pageSize: 50
        ).rows
        #expect(all.count >= 16)
        #expect(filtered.count >= 8)
        #expect(filtered.count < all.count)
    }
}
