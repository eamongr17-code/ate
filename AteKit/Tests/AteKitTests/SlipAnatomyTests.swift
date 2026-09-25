import Foundation
import Testing
@testable import AteKit

@Suite("Slip anatomy")
struct SlipAnatomyTests {

    @Test("The feed prints the words for one or two dishes, and drops them from three")
    func feedWords() {
        #expect(SlipAnatomy.showsWords(on: .feed, dishCount: 0))
        #expect(SlipAnatomy.showsWords(on: .feed, dishCount: 1))
        #expect(SlipAnatomy.showsWords(on: .feed, dishCount: 2))
        #expect(SlipAnatomy.showsWords(on: .feed, dishCount: 3) == false)
        #expect(SlipAnatomy.showsWords(on: .feed, dishCount: 7) == false)
    }

    @Test("The journal and a profile always print the words")
    func otherSurfaces() {
        for count in [0, 1, 2, 3, 9] {
            #expect(SlipAnatomy.showsWords(on: .journal, dishCount: count))
            #expect(SlipAnatomy.showsWords(on: .profile, dishCount: count))
        }
    }

    @Test("The journal prints the words whole; the feed and a profile clamp them at two lines")
    func wordClamp() {
        #expect(SlipAnatomy.wordsLineLimit(on: .journal) == nil)
        #expect(SlipAnatomy.wordsLineLimit(on: .feed) == 2)
        #expect(SlipAnatomy.wordsLineLimit(on: .profile) == 2)
    }

    @Test("A suburb is the place's locality, and a blank one is no suburb at all")
    func suburb() {
        let id = UUID()
        #expect(EntryCard.Place(id: id, name: "Tipo 00", locality: "CBD").suburb == "CBD")
        #expect(EntryCard.Place(id: id, name: "Tipo 00", locality: " Collingwood North ").suburb
            == "Collingwood North")
        #expect(EntryCard.Place(id: id, name: "Tipo 00", locality: "").suburb == nil)
        #expect(EntryCard.Place(id: id, name: "Tipo 00", locality: "  ").suburb == nil)
        #expect(EntryCard.Place(id: id, name: "Tipo 00").suburb == nil)
    }

    /// `city` holds "361 Little Bourke St, Melbourne VIC 3000" on rows resolved before 0031. It is
    /// never a label: no locality prints no suburb.
    @Test("A suburb never falls back to the city")
    func neverCity() {
        let mangled = EntryCard.Place(id: UUID(), name: "Tipo 00",
                                      city: "361 Little Bourke St, Melbourne VIC 3000")
        #expect(mangled.suburb == nil)
    }

    @Test("A place without a locality key still decodes, and one with it prints it")
    func decodesLocality() throws {
        let bare = "{\"id\":\"B7E00000-0000-4000-8000-000000000001\",\"name\":\"Tipo 00\",\"city\":\"Melbourne\"}"
        let place = try JSONDecoder().decode(EntryCard.Place.self, from: Data(bare.utf8))
        #expect(place.locality == nil)
        #expect(place.suburb == nil)
        let located = "{\"id\":\"B7E00000-0000-4000-8000-000000000001\",\"name\":\"Tipo 00\",\"locality\":\"CBD\"}"
        #expect(try JSONDecoder().decode(EntryCard.Place.self, from: Data(located.utf8)).suburb == "CBD")
        // 0035 sends `locality: null` for a place it cannot derive one for.
        let null = "{\"id\":\"B7E00000-0000-4000-8000-000000000001\",\"name\":\"Tipo 00\",\"locality\":null}"
        #expect(try JSONDecoder().decode(EntryCard.Place.self, from: Data(null.utf8)).suburb == nil)
    }
}
