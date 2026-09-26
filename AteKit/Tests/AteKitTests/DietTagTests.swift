import Foundation
import Testing
@testable import AteKit

@Suite("Dietary tags — typed after a dish, like a score")
struct DietTagTests {

    /// Runs the rule with the caret at the end of `text`, the way the editor asks it once the person
    /// has typed the move-on character (the caret sits before it).
    private func candidate(_ text: String) -> (String, DietTag)? {
        let caret = text.utf16.count
        guard let found = DietTagLiteral.candidate(in: text, caretUTF16: caret) else { return nil }
        let units = Array(text.utf16)
        return (String(decoding: units[found.span.location..<found.span.endLocation], as: UTF16.self), found.mark.tag)
    }

    @Test("the five codes, straight after a dish, in any case", arguments: [
        ("Tiramisu v", "v", DietTag.v),
        ("prawn spaghetti gf", "gf", .gf),
        ("the burger GF", "GF", .gf),
        ("mushroom risotto vg", "vg", .vg),
        ("cheesecake df", "df", .df),
        ("pad thai nf", "nf", .nf)
    ])
    func promotes(text: String, literal: String, tag: DietTag) throws {
        let found = try #require(candidate(text))
        #expect(found.0 == literal, "the characters they typed are the token's own")
        #expect(found.1 == tag)
    }

    @Test("two letters that mean something else stay words", arguments: [
        "went with my gf",           // girlfriend
        "it was v",                  // "very", mid-sentence
        "a v",                       // article
        "gf",                        // nothing before it
        "tiramisu 3.0 v",            // after a score, not a dish
        "tiramisu,v",                // no space: not a separate word
        "tiramisu  gfx",             // not a code
        "burger vgn",                // three letters
        "dinner with gf"             // connective
    ])
    func refuses(text: String) {
        #expect(candidate(text) == nil)
    }

    @Test("a second tag after the first is still a tag")
    func secondTag() throws {
        let found = try #require(candidate("salad gf vg"))
        #expect(found.1 == .vg)
    }

    @Test("a code already inside a token is never promoted twice")
    func alreadyAToken() {
        let text = "Tiramisu v"
        let composition = EntryComposition(plain: text, spans: [
            EntryTokenSpan(token: EntryToken(kind: .tag(DietTagMark(.v))), span: TextSpan(location: 9, length: 1))
        ])
        #expect(composition.pendingTagLiteral(atDisplayOffset: composition.displayString.utf16.count) == nil)
        #expect(composition.tags == [.v])
    }

    @Test("a tag token keeps the characters as typed, so the words are never rewritten")
    func plainTextIsVerbatim() {
        let token = EntryToken(kind: .tag(DietTagMark(tag: .gf, text: "GF")))
        #expect(token.plainText == "GF")
        #expect(token.tag == .gf)
        #expect(DietTag.gf.label == "GF")
        #expect(DietTag.vg.spokenName == "vegan")
    }

    // MARK: - The wire

    @Test("entry_cards items decode tags as lowercase codes, and an unknown code is dropped")
    func decodesTags() throws {
        let json = """
        {"review_id":"\(UUID())","dish_id":"\(UUID())","dish_name":"Tiramisu","position":1,
         "tags":["v","GF","keto","v"]}
        """
        let item = try JSONDecoder().decode(EntryCard.Item.self, from: Data(json.utf8))
        #expect(item.tags == [.v, .gf])
    }

    @Test("a row served before the column existed simply has no tags")
    func tagsAreOptional() throws {
        let json = """
        {"review_id":"\(UUID())","dish_id":"\(UUID())","dish_name":"Tiramisu","position":1}
        """
        let item = try JSONDecoder().decode(EntryCard.Item.self, from: Data(json.utf8))
        #expect(item.tags.isEmpty)
    }

    @Test("the preview sorter lifts a tag out of the dish's name")
    func previewSorterReadsTags() throws {
        let lines = PreviewSorter.sort(body: "Tiramisu v 3.0 a bit flat after that.")
        let line = try #require(lines.first)
        #expect(line.dishName == "Tiramisu")
        #expect(line.tags == [.v])
        #expect(line.score?.value == 3.0)
    }

    // MARK: - The contract (#61)

    /// Words with a tag chip on the given code, found rather than hand-counted.
    private func words(_ text: String, chipOn code: String) -> EntryComposition {
        let range = (text as NSString).range(of: code, options: .backwards)
        return EntryComposition(plain: text, spans: [
            EntryTokenSpan(token: EntryToken(kind: .tag(DietTagMark(tag: DietTag(code: code)!, text: code))),
                           span: TextSpan(range))
        ])
    }

    @Test("tag_tokens count Unicode scalars, not UTF-16", arguments: [
        ("ragù gf", 5),                  // precomposed ù: one scalar, one unit
        ("ragu\u{0300} gf", 6),          // decomposed ù: two scalars, two units
        ("🍝 ragù gf", 7),               // the emoji is two UTF-16 units and ONE scalar
        ("Tiramisu 🍰🍰 v", 12)
    ])
    func scalarOffsets(text: String, offset: Int) throws {
        let code = text.hasSuffix(" v") ? "v" : "gf"
        let tokens = words(text, chipOn: code).tagTokens
        #expect(tokens == [TagToken(offset: offset, length: code.unicodeScalars.count)])
        // And the scalar slice really is the code.
        let scalars = Array(text.unicodeScalars)
        let token = try #require(tokens.first)
        #expect(String(String.UnicodeScalarView(scalars[token.offset..<token.offset + token.length])) == code)
    }

    @Test("the sort request carries tag_tokens, and a sort without chips is the request it always was")
    func sortRequestEncoding() throws {
        let id = try #require(UUID(uuidString: "A7E00000-0000-4000-8000-000000000142"))
        let withTags = SortEntryRequest(entryID: id, force: false, tagTokens: [TagToken(offset: 23, length: 2)])
        let encoded = try JSONEncoder().encode(withTags)
        let json = try #require(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let tokens = try #require(json["tag_tokens"] as? [[String: Int]])
        #expect(tokens == [["offset": 23, "length": 2]])
        #expect(json["entry_id"] as? String == id.uuidString)
        #expect(json["force"] as? Bool == false)
        #expect(json["dry_run"] as? Bool == false)

        let plain = try #require(try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(SortEntryRequest(entryID: id, force: true))
        ) as? [String: Any])
        #expect(plain["tag_tokens"] == nil)
        #expect(Set(plain.keys) == ["entry_id", "force", "dry_run"])
    }

    @Test("a line's tags are PATCHed as the whole set, lowercase; [] clears them")
    func tagsPatchEncoding() throws {
        let body = try JSONEncoder().encode(ReviewTagsPatch(tags: [.gf, .v, .gf]))
        #expect(String(bytes: body, encoding: .utf8) == #"{"tags":["gf","v"]}"#)
        let cleared = try JSONEncoder().encode(ReviewTagsPatch(tags: []))
        #expect(String(bytes: cleared, encoding: .utf8) == #"{"tags":[]}"#)
    }

    @Test("an outbox queued before tags existed still reads, and the chips ride to the late sort")
    func outboxCarriesTokens() throws {
        let insert = QueuedInsert(NewEntry(id: UUID(), authorID: UUID(), body: "Tiramisu v 3.0",
                                           restaurantID: nil, createdAt: Date(timeIntervalSince1970: 1)))
        var queued = QueuedEntry(entry: insert, pendingPhotos: [])
        queued.tagTokens = [TagToken(offset: 9, length: 1)]
        let decoded = try JSONDecoder().decode(QueuedEntry.self, from: JSONEncoder().encode(queued))
        #expect(decoded.tagTokens == [TagToken(offset: 9, length: 1)])

        // The same row as a pre-tags queue wrote it: no key at all.
        let written = try JSONEncoder().encode(queued)
        var legacy = try #require(try JSONSerialization.jsonObject(with: written) as? [String: Any])
        legacy.removeValue(forKey: "tagTokens")
        let old = try JSONDecoder().decode(QueuedEntry.self, from: JSONSerialization.data(withJSONObject: legacy))
        #expect(old.tagTokens == nil)
    }

    @Test("dish_tag_added carries the code")
    func event() {
        let event = EntryEvents.dishTagAdded(.gf)
        #expect(event.name == "dish_tag_added")
        #expect(event.parameters == ["code": "gf"])
    }
}
