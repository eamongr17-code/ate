import Foundation
import Testing

@testable import AteKit

/// **What the Search tab's RPCs actually send** (migrations 0031/0032), decoded from the payloads
/// written down in `docs/backend/integration-design.md` — including the nulls the happy path never
/// shows you. These run in a plain `swift test`; the staging suite next door proves the server still
/// sends them.
@Suite("Search scopes decoding")
struct SearchScopesDecodingTests {

    // MARK: - Places

    @Test("A place row is name · cuisine · score, and an unrated place has no score")
    func placeRowDecodes() throws {
        let json = Data("""
        [{"restaurant_id":"1f2e3d4c-5b6a-4798-8899-aabbccddeeff","name":"Tipo 00",
          "cuisine":"Italian","locality":"Melbourne","avg_rating":4.3,"review_count":18,
          "people_count":6,"dish_count":9,"cover_url":"https://x/y.jpg","match_tier":1},
         {"restaurant_id":"2f2e3d4c-5b6a-4798-8899-aabbccddeeff","name":"Tipo Cafe",
          "cuisine":null,"locality":null,"avg_rating":null,"review_count":0,
          "people_count":0,"dish_count":0,"cover_url":null,"match_tier":2}]
        """.utf8)
        let rows = try PostgRESTDate.decoder.decode([SearchPlaceRow].self, from: json)

        #expect(rows.count == 2)
        #expect(rows[0].name == "Tipo 00")
        #expect(rows[0].avgRating == 4.3)
        // An average is printed as sent — 4.3, never rounded to the nearest half. Only stars round.
        #expect(ScoreFormat.average(rows[0].avgRating) == "4.3")
        // Nobody has scored the second one. Null is not zero, and the row is still a valid result.
        #expect(rows[1].avgRating == nil)
        #expect(rows[1].cuisine == nil)
        #expect(rows[1].locality == nil)
        #expect(rows[1].coverURL == nil)
        // The tier is the leading sort key: the exact-er match leads.
        #expect(rows[0].matchTier < rows[1].matchTier)
    }

    @Test("Nearby carries a distance, which is the cursor, not something the artboard prints")
    func nearbyRowDecodes() throws {
        let json = Data("""
        [{"restaurant_id":"1f2e3d4c-5b6a-4798-8899-aabbccddeeff","name":"Tipo 00","cuisine":"Italian",
          "locality":"Melbourne","avg_rating":4.3,"review_count":18,"people_count":6,"dish_count":9,
          "cover_url":null,"distance_m":184.27}]
        """.utf8)
        let rows = try PostgRESTDate.decoder.decode([NearbyPlaceRow].self, from: json)
        #expect(rows[0].distanceM == 184.27)
        #expect(rows[0].cuisine == "Italian")
    }

    // MARK: - Dishes

    @Test("A dish row carries its place and its cover, and an unscored dish still comes back")
    func dishRowDecodes() throws {
        let json = Data("""
        [{"dish_id":"3f2e3d4c-5b6a-4798-8899-aabbccddeeff","dish_name":"Tagliatelle al ragù",
          "restaurant_id":"1f2e3d4c-5b6a-4798-8899-aabbccddeeff","restaurant_name":"Tipo 00",
          "restaurant_locality":"Melbourne","score":4.6,"review_count":5,"scored_count":4,
          "people_count":4,"cover_url":"https://x/ragu.jpg","match_tier":2},
         {"dish_id":"4f2e3d4c-5b6a-4798-8899-aabbccddeeff","dish_name":"Focaccia",
          "restaurant_id":"1f2e3d4c-5b6a-4798-8899-aabbccddeeff","restaurant_name":"Tipo 00",
          "restaurant_locality":null,"score":null,"review_count":1,"scored_count":0,
          "people_count":1,"cover_url":null,"match_tier":3}]
        """.utf8)
        let rows = try PostgRESTDate.decoder.decode([SearchDishRow].self, from: json)

        // The accented name survives the wire verbatim — the whole point of the folded match key is
        // that the QUERY is folded, never the menu's spelling.
        #expect(rows[0].dishName == "Tagliatelle al ragù")
        #expect(rows[0].restaurantName == "Tipo 00")
        #expect(rows[0].score == 4.6)
        // DESIGN rule 7: no score is null, not zero — an empty star, no text.
        #expect(rows[1].score == nil)
        #expect(rows[1].scoredCount == 0)
        // Every returned dish has at least one line the viewer can see (0031). A shell is not a result.
        #expect(rows.allSatisfy { $0.reviewCount > 0 })
    }

    // MARK: - People

    @Test("A person row is handle · name · avatar, and says whether it is you")
    func personRowDecodes() throws {
        let json = Data("""
        [{"user_id":"5f2e3d4c-5b6a-4798-8899-aabbccddeeff","username":"jessw","name":"Jess W",
          "avatar_url":"https://x/j.jpg","city":"Melbourne","is_me":false,"match_tier":1},
         {"user_id":"6f2e3d4c-5b6a-4798-8899-aabbccddeeff","username":"eamon","name":"Eamon",
          "avatar_url":null,"city":null,"is_me":true,"match_tier":0}]
        """.utf8)
        let rows = try PostgRESTDate.decoder.decode([SearchPersonRow].self, from: json)

        #expect(rows[0].username == "jessw")
        #expect(rows[0].isMe == false)
        // An avatar nobody set is null, never "" — an empty string is a broken image request.
        #expect(rows[1].avatarURL == nil)
        #expect(rows[1].isMe)
    }

    // MARK: - Saved

    @Test("A saved row is my_saved_dishes' own shape, provenance and all")
    func savedRowDecodes() throws {
        let json = Data("""
        [{"dish_id":"3f2e3d4c-5b6a-4798-8899-aabbccddeeff","dish_name":"Tagliatelle al ragù",
          "restaurant_id":"1f2e3d4c-5b6a-4798-8899-aabbccddeeff","restaurant_name":"Tipo 00",
          "restaurant_city":"361 Little Bourke St, Melbourne VIC 3000","restaurant_locality":"Melbourne",
          "dish_score":4.6,"dish_cover_url":"https://x/ragu.jpg",
          "source_entry_id":"7f2e3d4c-5b6a-4798-8899-aabbccddeeff",
          "source_user_id":"5f2e3d4c-5b6a-4798-8899-aabbccddeeff","source_username":"jessw",
          "saved_at":"2026-09-21T09:14:02.481932+00:00","cover_url":"https://x/ragu.jpg"},
         {"dish_id":"8f2e3d4c-5b6a-4798-8899-aabbccddeeff","dish_name":"Focaccia",
          "restaurant_id":"1f2e3d4c-5b6a-4798-8899-aabbccddeeff","restaurant_name":"Tipo 00",
          "restaurant_city":null,"restaurant_locality":null,"dish_score":null,"dish_cover_url":null,
          "source_entry_id":null,"source_user_id":null,"source_username":null,
          "saved_at":"2026-09-20T09:14:02+00:00","cover_url":null}]
        """.utf8)
        let rows = try PostgRESTDate.decoder.decode([SearchSavedRow].self, from: json)

        #expect(rows[0].sourceUsername == "jessw")
        #expect(rows[0].coverURL == rows[0].dishCoverURL, "cover_url IS dish_cover_url")
        // This is why the row carries a locality at all: `restaurant_city` can be the live-Google
        // mangle on any row resolved before the edge function was fixed.
        #expect(rows[0].restaurantCity?.contains(",") == true)
        #expect(rows[0].restaurantLocality == "Melbourne")
        // A save with no provenance (saved from a place page, not somebody's entry) is normal.
        #expect(rows[1].sourceEntryID == nil)
        #expect(rows[1].sourceUsername == nil)
        // Microseconds survive: `saved_at` is half the keyset cursor, and a truncated one matches
        // nothing.
        #expect(rows[0].savedAt > rows[1].savedAt)
        #expect(rows[0].savedAt.timeIntervalSince1970 != rows[0].savedAt.timeIntervalSince1970.rounded(.down))
    }

    // MARK: - search_all (shape unchanged; the place subtitle moved)

    @Test("search_all keeps its shape, and a place with no cuisine now subtitles its locality")
    func searchAllRowDecodes() throws {
        let json = Data("""
        [{"kind":"place","id":"1f2e3d4c-5b6a-4798-8899-aabbccddeeff","title":"Tipo 00",
          "subtitle":"Italian","score":4.3,"match_rank":0.6,
          "detail":{"city":"361 Little Bourke St, Melbourne VIC 3000","cuisine":"Italian",
                    "address":"361 Little Bourke St, Melbourne VIC 3000, Australia",
                    "locality":"Melbourne","people_count":6}},
         {"kind":"place","id":"2f2e3d4c-5b6a-4798-8899-aabbccddeeff","title":"Kirk's Wine Bar",
          "subtitle":"Melbourne","score":null,"match_rank":0.4,
          "detail":{"city":"Melbourne","cuisine":null,"address":null,"locality":"Melbourne",
                    "people_count":0}},
         {"kind":"person","id":"5f2e3d4c-5b6a-4798-8899-aabbccddeeff","title":"jessw","subtitle":"Jess W",
          "score":null,"match_rank":1.0,"detail":{"avatar_url":"https://x/j.jpg","city":"Melbourne"}}]
        """.utf8)
        let rows = try PostgRESTDate.decoder.decode([SearchAllWireRow].self, from: json)

        #expect(rows.map(\.kind) == ["place", "place", "person"])
        // Cuisine when there is one…
        #expect(rows[0].subtitle == "Italian")
        // …the derived LOCALITY when there is not. Never the stored city, which is the mangle above.
        #expect(rows[1].subtitle == "Melbourne")
        #expect(rows[1].detail?["locality"]?.stringValue == "Melbourne")
        #expect(rows[0].detail?["city"]?.stringValue?.contains("VIC") == true)
    }

    // MARK: - Account + blocks

    @Test("A blocked-list row names the person the profiles policy hides")
    func myBlocksRowDecodes() throws {
        let json = Data("""
        [{"blocked_id":"5f2e3d4c-5b6a-4798-8899-aabbccddeeff","username":"noisy","name":"Noisy Neighbour",
          "avatar_url":"https://x/n.jpg","city":"Fitzroy","created_at":"2026-09-22T11:02:44.9127+00:00"}]
        """.utf8)
        let rows = try PostgRESTDate.decoder.decode([MyBlockRow].self, from: json)
        #expect(rows[0].username == "noisy")
        #expect(rows[0].name == "Noisy Neighbour")
    }

    @Test("delete_account answers whether the auth row itself went")
    func deleteAccountResultDecodes() throws {
        let done = try PostgRESTDate.decoder.decode(
            DeleteAccountResult.self, from: Data(#"{"ok":true,"auth_user_deleted":true}"#.utf8)
        )
        #expect(done.ok)
        #expect(done.authUserDeleted)

        // The fallback: the data is gone, the auth row survived. Not a success to swallow — it means
        // the account can still be signed into and we owe it the admin API.
        let partial = try PostgRESTDate.decoder.decode(
            DeleteAccountResult.self, from: Data(#"{"ok":true,"auth_user_deleted":false}"#.utf8)
        )
        #expect(partial.ok)
        #expect(partial.authUserDeleted == false)
    }
}
