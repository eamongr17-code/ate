import Foundation
import PostgREST
import Supabase
import Testing

@testable import AteKit

/// **The live read surface, against staging.** `StagingContractTests` covers the tables V1 inherited;
/// this covers the three reads the app actually renders today — `entry_cards`, `get_entry_feed` and
/// `my_saved_dishes` — because a unit test can only prove we decode a payload we wrote down
/// ourselves.
///
/// What these are really guarding:
///
/// - **The row shape.** `EntryCard` has no forgiving decoder: a renamed or dropped column is a
///   `keyNotFound`, not a silent nil, and that is the point. Everything the design draws — slip,
///   feed row, entry page, receipt — is this one row at four densities.
/// - **The offsets.** `place_offset` and each line's `evidence_offset` are 0-based **Unicode scalar**
///   offsets into `body`. On an ASCII body a UTF-16 offset and a scalar offset are identical, so the
///   day the server gets this wrong is the day somebody writes `ragù` — which the seed does. Every
///   offset staging serves is sliced here and read back.
/// - **The cursor.** `get_entry_feed` pages on `(created_at, id)` with microsecond timestamps; a
///   cursor formatted to milliseconds silently skips whole rows rather than failing.
///
/// Opt-in exactly like the other suite: `ATE_CONTRACT_TESTS=1`, staging only, never prod (rule 5).
@Suite("Entry cards — staging contract", .enabled(if: StagingContract.isEnabled), .serialized)
struct EntryCardsContractTests {

    func client() async throws -> AteAPIClient {
        try await StagingContract.Backend.shared.client()
    }

    /// Rows straight off the view, decoded the way the app decodes them: from the response's own
    /// bytes through ``PostgRESTDate/decoder``, never the client's default decoder.
    func cards(
        _ client: AteAPIClient,
        limit: Int = 50,
        refine: @Sendable (PostgrestFilterBuilder) -> PostgrestFilterBuilder = { $0 }
    ) async throws -> [EntryCard] {
        let data = try await refine(client.supabase.from(EntryCard.table).select(EntryCard.columns))
            .order("created_at", ascending: false)
            .order("id", ascending: false)
            .limit(limit)
            .execute()
            .data
        return try PostgRESTDate.decoder.decode([EntryCard].self, from: data)
    }

    // MARK: - The row

    @Test("entry_cards decodes, with a scored line, an unscored line and an entry that has no place")
    func decodesEntryCards() async throws {
        let client = try await client()
        let rows = try await cards(client)
        #expect(rows.isEmpty == false, "an empty entry_cards can't test the row the whole app renders")

        for card in rows {
            #expect(card.orderNumber > 0)
            // The view's own counters, not ours: a mismatch means the aggregate drifted from the
            // lines it counts, and the receipt footer would print a number the bill contradicts.
            #expect(card.dishCount == card.items.count)
            #expect(card.photoCount == card.photos.count)
            #expect(card.photos.map(\.position) == card.photos.map(\.position).sorted())
            // The lines arrive in the order they print. `position` is 1-based and strictly
            // increasing — NOT consecutive: staging serves `[1, 3]`, because a parsed line that
            // failed validation leaves its number behind. The bill numbers what it draws (`01`,
            // `02`) off the row's index for exactly that reason.
            #expect(card.items.allSatisfy { $0.position >= 1 })
            #expect(zip(card.items, card.items.dropFirst()).allSatisfy { $0.position < $1.position })
            // `avg_score` is over SCORED lines only — an unscored dish is not a zero (DESIGN rule 7).
            let scores = card.items.compactMap(\.score?.value)
            if scores.isEmpty {
                #expect(card.avgScore == nil, "an entry with no numbers has no average, not 0")
            } else {
                let mean = scores.reduce(0, +) / Double(scores.count)
                #expect(abs((card.avgScore ?? -1) - mean) < 0.01)
            }
            // A place that is there is a whole place: the pill and the page title are its name.
            if let place = card.place {
                #expect(place.id == card.restaurantID)
                #expect(place.name.isEmpty == false)
            }
        }

        // Both halves of the score contract, asked for by name. A page of recent entries is mostly
        // scored lines, so sampling one page proves only the half that is common.
        #expect(rows.contains { $0.items.contains { $0.score != nil } }, "staging must hold a scored line")
        let unscored = try await cards(client, limit: 200)
            .flatMap(\.items)
            .filter { $0.score == nil }
        #expect(
            unscored.isEmpty == false,
            "staging must hold an unscored line — a dish they wrote about and gave no number is normal"
        )

        // No place is a designed state, not an error: the sorter parks its findings in `sort_plan`
        // and the page still prints the words (contract, The sorter). The query is the assertion
        // either way — `place` has to be nullable in the view for this to return rather than 400.
        let placeless = try await cards(client, limit: 5) { $0.is("restaurant_id", value: nil) }
        withKnownIssue(
            """
            staging holds no place-less entry. Every seeded entry names a restaurant we already \
            have, so the sorter's parked state — the one a real first user hits constantly — has \
            no live row to decode. Seed one and this asserts on it.
            """,
            isIntermittent: true
        ) {
            #expect(placeless.isEmpty == false)
        }
        #expect(placeless.allSatisfy { $0.place == nil })
        #expect(placeless.allSatisfy { $0.placeOffset == nil && $0.placeLength == nil })
    }

    @Test("every offset the view serves is a scalar offset that still points at what it names")
    func offsetsPointAtTheirText() async throws {
        let client = try await client()
        let rows = try await cards(client, limit: 200)

        var checkedPlace = 0
        var checkedEvidence = 0
        var checkedMention = 0

        for card in rows {
            let scalars = Array(card.body.unicodeScalars)
            let body = BodyOffsets(card.body)

            if let offset = card.placeOffset, let length = card.placeLength {
                // In range as SCALARS. The same number read as UTF-16 would run past the end of a
                // body with an accent late in it — which is the whole reason the unit is in the
                // contract.
                #expect(offset >= 0 && offset + length <= scalars.count, "place offset outside \(card.id)'s body")
                let span = try #require(body.span(scalarOffset: offset, scalarLength: length))
                let named = body.text(in: span)
                #expect(named.isEmpty == false)
                // The words really do name the place there. `place_query` may be the person's
                // spelling rather than the catalogue's ("tipo 00"), so this is a containment test
                // in one direction or the other, not equality.
                if let place = card.place, card.updatedAt <= (card.sortedAt ?? .distantPast) {
                    let lowercasedName = place.name.lowercased()
                    let lowercasedSlice = named.lowercased()
                    #expect(
                        lowercasedName.contains(lowercasedSlice) || lowercasedSlice.contains(lowercasedName),
                        "\(card.id): place offsets point at \"\(named)\", which does not name \(place.name)"
                    )
                }
                checkedPlace += 1
            }

            for item in card.items {
                if let offset = item.evidenceOffset, let length = item.evidenceLength {
                    #expect(
                        offset >= 0 && offset + length <= scalars.count,
                        "evidence offset outside \(card.id)'s body"
                    )
                    let span = try #require(body.span(scalarOffset: offset, scalarLength: length))
                    let evidence = body.text(in: span)
                    if let score = item.score, card.updatedAt <= (card.sortedAt ?? .distantPast) {
                        // The contract's own staleness test: the slice holds the score's digits.
                        // "4.5 stars" and "a clear 4" are both legal evidence for 4.5 and 4.0.
                        #expect(
                            Self.holdsTheScore(evidence, score),
                            "\(card.id): \"\(evidence)\" is evidence for \(ScoreFormat.halfStep(score.value))"
                        )
                    }
                    checkedEvidence += 1
                }

                if let offset = item.mentionOffset, let length = item.mentionLength {
                    #expect(offset >= 0 && offset + length <= scalars.count, "mention offset outside \(card.id)'s body")
                    let span = try #require(body.span(scalarOffset: offset, scalarLength: length))
                    #expect(body.text(in: span).isEmpty == false)
                    checkedMention += 1
                }
            }
        }

        // A view that stopped serving offsets would otherwise pass every assertion above by having
        // nothing to check. The sorter writes all three, so staging must hold all three.
        #expect(checkedPlace > 0, "no place offsets in staging — the view or the sorter stopped writing them")
        #expect(checkedEvidence > 0, "no score offsets in staging")
        #expect(checkedMention > 0, "no dish offsets in staging")
    }

    @Test("a card with offsets renders its pills through the server's answer, not a search")
    func offsetsDriveTheComposition() async throws {
        let client = try await client()
        let rows = try await cards(client, limit: 200)
        // A fresh card (never edited since it was sorted) whose score the server can point at: the
        // exact case `EntryBodyTokens` is supposed to take a lookup on rather than a match.
        let card = try #require(
            rows.first { card in
                card.updatedAt <= (card.sortedAt ?? .distantPast)
                    && card.items.contains { $0.score != nil && $0.evidenceOffset != nil }
            },
            "staging must hold a sorted, unedited entry with a located score"
        )

        let composition = EntryBodyTokens.composition(for: card)
        #expect(composition.plain == card.body, "the words are never rewritten (DESIGN rule 9)")
        for span in composition.spans {
            // `EntryComposition` drops a span whose slice is not the token's text, so this holds by
            // construction — and that is what makes it worth asserting on live rows: it is the seam
            // that would have to be lying for a pill to sit on the wrong characters.
            let body = BodyOffsets(card.body)
            #expect(body.text(in: span.span) == span.token.plainText)
        }
        #expect(composition.spans.contains { $0.token.score != nil }, "a located score must become a pill")
    }

    // MARK: - The feed

    @Test("get_entry_feed pages on its cursor: no repeats, no gaps, newest first")
    func entryFeedPages() async throws {
        try await StagingExclusive.shared.run {
            let client = try await client()
            let pageSize = 3
            var cursor: PageCursor?
            var seen: [EntryCard] = []
            var pages = 0

            repeat {
                let rows = try await feedPage(client, cursor: cursor, pageSize: pageSize)
                if pages == 0 {
                    #expect(rows.isEmpty == false, "a signed-in viewer's feed must not be empty — the empty-feed trap")
                }
                seen.append(contentsOf: rows)
                cursor = rows.count < pageSize ? nil : rows.last.map { PageCursor(createdAt: $0.createdAt, id: $0.id) }
                pages += 1
            } while cursor != nil && pages < 8

            #expect(Set(seen.map(\.id)).count == seen.count, "the cursor served a row twice")
            for (newer, older) in zip(seen, seen.dropFirst()) {
                let descending = newer.createdAt > older.createdAt
                    || (newer.createdAt == older.createdAt && newer.id.uuidString > older.id.uuidString)
                #expect(descending, "\(newer.id) should sort before \(older.id)")
            }
            // The feed is public entries by other people: `p_include_own` defaults false, because your
            // own visits live in the journal (contract, Reads).
            #expect(seen.allSatisfy { $0.visibility == .public })
            #expect(seen.allSatisfy { $0.isMine == false })
            // A row nobody can put a name to is not renderable.
            #expect(seen.allSatisfy { ($0.author?.username.isEmpty == false) })
        }
    }

    /// One page of `get_entry_feed`, built the way `integration-design.md` writes the cursor
    /// contract: first page → nulls, next page → the LAST row's `created_at` **and** `id`.
    func feedPage(_ client: AteAPIClient, cursor: PageCursor?, pageSize: Int) async throws -> [EntryCard] {
        let parameters: [String: AnyJSON] = [
            "p_cursor_created_at": cursor.map { .string(PostgRESTTimestamp.string(from: $0.createdAt)) } ?? .null,
            "p_cursor_id": cursor.map { .string($0.id.uuidString.lowercased()) } ?? .null,
            "p_page_size": .integer(pageSize)
        ]
        let data = try await client.supabase.rpc("get_entry_feed", params: parameters).execute().data
        return try PostgRESTDate.decoder.decode([EntryCard].self, from: data)
    }

    // MARK: - Saved

    @Test("my_saved_dishes decodes, and an empty one is still a shape")
    func savedDishesDecode() async throws {
        let client = try await client()
        // Naming every column is the assertion: PostgREST answers a select for a column that is not
        // there with a 400, so this fails loudly on a rename even when the viewer has saved nothing.
        let data = try await client.supabase
            .from("my_saved_dishes")
            .select(SavedDishRow.columns)
            .order("restaurant_name", ascending: true)
            .order("saved_at", ascending: false)
            .limit(50)
            .execute()
            .data
        let rows = try PostgRESTDate.decoder.decode([SavedDishRow].self, from: data)

        for row in rows {
            #expect(row.dishName.isEmpty == false)
            #expect(row.restaurantName.isEmpty == false)
            // Saved dishes group by restaurant on the client, so the grouping key has to be there.
            #expect(row.restaurantID != row.dishID)
            if let score = row.dishScore {
                #expect(score >= 0.5 && score <= 5)
            }
        }
        // Sorted by the server, not by us — the client groups, it does not re-order.
        #expect(rows.map(\.restaurantName) == rows.map(\.restaurantName).sorted())
    }

    /// The saved row as the contract writes it. Local to this suite on purpose: the screen that
    /// renders it is still being built, and a contract test should pin the wire, not wait for a type.
    struct SavedDishRow: Decodable, Sendable {
        static let columns = """
            dish_id,dish_name,restaurant_id,restaurant_name,restaurant_city,dish_score,\
            dish_cover_url,source_entry_id,source_user_id,source_username,saved_at
            """

        let dishID: UUID
        let dishName: String
        let restaurantID: UUID
        let restaurantName: String
        let restaurantCity: String?
        let dishScore: Double?
        let dishCoverURL: String?
        let sourceEntryID: UUID?
        let sourceUserID: UUID?
        let sourceUsername: String?
        let savedAt: Date

        enum CodingKeys: String, CodingKey {
            case dishID = "dish_id"
            case dishName = "dish_name"
            case restaurantID = "restaurant_id"
            case restaurantName = "restaurant_name"
            case restaurantCity = "restaurant_city"
            case dishScore = "dish_score"
            case dishCoverURL = "dish_cover_url"
            case sourceEntryID = "source_entry_id"
            case sourceUserID = "source_user_id"
            case sourceUsername = "source_username"
            case savedAt = "saved_at"
        }
    }

    /// Whether a piece of evidence really holds the number it was recorded for. `4.5` is written
    /// `4.5`; `4.0` is almost always written `4`, and both are the score's digits.
    static func holdsTheScore(_ evidence: String, _ score: Rating) -> Bool {
        let exact = ScoreFormat.halfStep(score.value)
        if evidence.contains(exact) { return true }
        guard score.value == score.value.rounded() else { return false }
        let whole = String(Int(score.value))
        // Not just "contains a 4": "14" must not pass for a score of 4.
        return evidence.ranges(of: whole).contains { range in
            let before = range.lowerBound == evidence.startIndex
                ? nil : evidence[evidence.index(before: range.lowerBound)]
            let after = range.upperBound == evidence.endIndex ? nil : evidence[range.upperBound]
            let isDigit = { (character: Character?) in character.map { $0.isNumber || $0 == "." } ?? false }
            return isDigit(before) == false && isDigit(after) == false
        }
    }
}
