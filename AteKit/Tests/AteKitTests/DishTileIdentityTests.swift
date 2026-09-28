import Foundation
import Testing

@testable import AteKit

@Suite("Dish tile identity — a dish is never a blank")
struct DishTileIdentityTests {
    @Test("a monogram takes the initials of the significant words")
    func monogramInitials() {
        #expect(DishTileIdentity.monogram(for: "Prawn betel leaf") == "PB")
        // Hyphens split too, and "in" is a stop word: Son / law.
        #expect(DishTileIdentity.monogram(for: "Son-in-law eggs") == "SL")
        #expect(DishTileIdentity.monogram(for: "kouign-amann") == "KA")
    }

    @Test("stop words never become the monogram")
    func monogramSkipsStopWords() {
        // The bug this rule exists for: "CE"/"EP" instead of "CP".
        #expect(DishTileIdentity.monogram(for: "Cacio e Pepe") == "CP")
        #expect(DishTileIdentity.monogram(for: "The Duck") == "DU")
        #expect(DishTileIdentity.monogram(for: "Steak and chips") == "SC")
    }

    @Test("a one-word dish takes its first two letters")
    func monogramSingleWord() {
        #expect(DishTileIdentity.monogram(for: "Tonkotsu") == "TO")
        #expect(DishTileIdentity.monogram(for: "  Pho  ") == "PH")
    }

    @Test("an all-stop-word name still produces letters rather than an empty tile")
    func monogramAllStopWords() {
        // "A" and "la" are stops; one significant word is left, so it lends both letters.
        #expect(DishTileIdentity.monogram(for: "A la carte") == "CA")
        #expect(DishTileIdentity.monogram(for: "the of") == "TO")
    }

    @Test("a name with no letters at all falls back to the placeholder")
    func monogramPlaceholder() {
        #expect(DishTileIdentity.monogram(for: "") == "??")
        #expect(DishTileIdentity.monogram(for: "   ") == "??")
        #expect(DishTileIdentity.monogram(for: "!!! ###") == "??")
    }

    @Test("leading punctuation is stripped before the initial is taken")
    func monogramStripsPunctuation() {
        #expect(DishTileIdentity.monogram(for: "\"Prawn\" betel") == "PB")
    }

    @Test("typographic detail degrades with the well")
    func typographicDegradation() {
        #expect(DishTileIdentity.typographicDetail(forWell: 96) == .fullName)
        #expect(DishTileIdentity.typographicDetail(forWell: 56) == .fullName)
        #expect(DishTileIdentity.typographicDetail(forWell: 44) == .firstWord)
        #expect(DishTileIdentity.typographicDetail(forWell: 32) == .firstWord)
        #expect(DishTileIdentity.typographicDetail(forWell: 24) == .twoLetters)
    }

    @Test("typographic text follows the degradation")
    func typographicText() {
        let name = "Prawn betel leaf"
        #expect(DishTileIdentity.typographicText(for: name, well: 96) == "Prawn betel leaf")
        #expect(DishTileIdentity.typographicText(for: name, well: 44) == "Prawn")
        #expect(DishTileIdentity.typographicText(for: name, well: 20) == "PB")
        // A blank name never renders a blank tile at any size.
        #expect(DishTileIdentity.typographicText(for: "  ", well: 96) == "??")
    }

    @Test("the palette index is stable for a given UUID and inside the palette")
    func paletteIndexIsStableAndInRange() {
        let id = UUID(uuidString: "6F9619FF-8B86-D011-B42D-00CF4FC964FF")!
        let first = DishTileIdentity.paletteIndex(for: id, count: 6)
        #expect(first == DishTileIdentity.paletteIndex(for: id, count: 6))
        #expect((0..<6).contains(first))
        // Pinned: this is the value a rebuilt binary, a different device and a later OS must agree
        // on. If this assertion changes, every dish in the app just changed colour.
        #expect(DishTileIdentity.stableHash(of: id) == 16_648_012_744_343_593_537)
    }

    @Test("a UUID's palette step doesn't depend on the process's hash seed")
    func paletteIndexIsNotSeeded() {
        // `hashValue` differs per launch; this must not. Same bytes, two `UUID` values.
        let bytes = UUID().uuid
        let (left, right) = (UUID(uuid: bytes), UUID(uuid: bytes))
        #expect(DishTileIdentity.stableHash(of: left) == DishTileIdentity.stableHash(of: right))
    }

    @Test("an empty palette can't crash a row")
    func paletteIndexGuardsEmpty() {
        #expect(DishTileIdentity.paletteIndex(for: UUID(), count: 0) == 0)
    }

    @Test("the palette spreads across its steps rather than favouring one")
    func paletteIndexSpreads() {
        var seen = Set<Int>()
        for _ in 0..<200 { seen.insert(DishTileIdentity.paletteIndex(for: UUID(), count: 6)) }
        #expect(seen.count == 6)
    }
}

@MainActor
@Suite("Letter tiles — neighbours never match")
struct NeighbourTileTests {
    @Test("neighbouring letter tiles never share an accent, and a list always paints the same way")
    func neighbourlyTiles() {
        let ids = (0..<400).map { _ in UUID() }
        let indices = DishTileIdentity.paletteIndices(for: ids, count: 5)
        #expect(indices.count == ids.count)
        #expect(zip(indices, indices.dropFirst()).allSatisfy { $0 != $1 })
        #expect(indices.allSatisfy { (0..<5).contains($0) })
        #expect(DishTileIdentity.paletteIndices(for: ids, count: 5) == indices)
    }

    @Test("a tile keeps its own accent unless the one above it already has it")
    func tilesKeepTheirOwn() {
        let ids = (0..<200).map { _ in UUID() }
        let own = ids.map { DishTileIdentity.paletteIndex(for: $0, count: 5) }
        let indices = DishTileIdentity.paletteIndices(for: ids, count: 5)
        #expect(indices.first == own.first)
        for position in 1..<ids.count where own[position] != indices[position - 1] {
            #expect(indices[position] == own[position])
        }
    }

    @Test("the same dish twice in a row still gets two accents")
    func sameDishTwice() {
        let id = UUID()
        let indices = DishTileIdentity.paletteIndices(for: [id, id, id], count: 5)
        #expect(indices[0] != indices[1] && indices[1] != indices[2])
    }
}

@Suite("The letter tile — a photo-less dish is never a grey square")
struct LetterTileTests {
    @Test("the name's own first letter, capitalised")
    func initial() {
        #expect(DishTileIdentity.initial(for: "Tiramisu") == "T")
        #expect(DishTileIdentity.initial(for: "cheeseburger") == "C")
        #expect(DishTileIdentity.initial(for: "'nduja pizza") == "N")
        #expect(DishTileIdentity.initial(for: "The Big Breakfast") == "T")
        #expect(DishTileIdentity.initial(for: "  ") == DishTileIdentity.initialPlaceholder)
    }

    @Test("the colour is the dish's, not the row's: the same id always picks the same accent")
    func stableColour() throws {
        let id = try #require(UUID(uuidString: "D7E00000-0000-4000-8000-000000000002"))
        let first = DishTileIdentity.paletteIndex(for: id, count: 5)
        #expect((0..<20).allSatisfy { _ in DishTileIdentity.paletteIndex(for: id, count: 5) == first })
        #expect((0..<5).contains(first))
    }
}
