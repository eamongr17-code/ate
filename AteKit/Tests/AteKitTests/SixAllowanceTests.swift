import Foundation
import Testing

@testable import AteKit

/// **Two 6s in any two months** (0091), as the slider sees it: which pill is locked, and what the
/// locked panel says.
@Suite("Six allowance")
struct SixAllowanceTests {
    /// "Tiramisu 6 and pasta 6" — or 4s — with each pill's span over its own text.
    private func words(_ ratings: [Rating]) -> (EntryComposition, [UUID]) {
        var plain = ""
        var spans: [EntryTokenSpan] = []
        for (index, rating) in ratings.enumerated() {
            plain += index == 0 ? "Tiramisu " : " and pasta "
            let token = EntryToken(kind: .score(rating))
            let location = plain.utf16.count
            plain += token.plainText
            let span = TextSpan(location: location, length: token.plainText.utf16.count)
            spans.append(EntryTokenSpan(token: token, span: span))
        }
        return (EntryComposition(plain: plain, spans: spans), spans.map(\.id))
    }

    @Test("one left: the first pill may be a 6; once it is, the next is locked and the first keeps it")
    func oneLeft() {
        let allowance = SixAllowance(left: 1, nextAt: nil)
        let (fresh, freshIDs) = words([.perfect, .perfect])
        #expect(allowance.lock(for: fresh, scoring: freshIDs[0]) == nil)

        let (one, ids) = words([.blownAway, .perfect])
        #expect(allowance.lock(for: one, scoring: ids[0]) == nil, "the pill holding the 6 keeps it")
        #expect(allowance.lock(for: one, scoring: ids[1]) == SixLock(nextAt: nil))
    }

    @Test("none left: every pill is locked, and the panel says when the next comes back")
    func noneLeft() throws {
        let next = try #require(ISO8601DateFormatter().date(from: "2026-12-14T09:00:00Z"))
        let allowance = SixAllowance(left: 0, nextAt: next)
        let (fresh, ids) = words([.perfect])
        let lock = try #require(allowance.lock(for: fresh, scoring: ids[0]))
        #expect(lock.word(timeZone: TimeZone(identifier: "Australia/Melbourne")!) == "Next 6 on 14 Dec")
        #expect(SixLock(nextAt: nil).word() == "No 6s left")
    }

    @Test("the RPC's row decodes, a missing date included")
    func decodes() throws {
        let json = #"[{"sixes_left":0,"next_at":"2026-12-14T09:00:00+00:00"},{"sixes_left":2,"next_at":null}]"#
        let data = Data(json.utf8)
        let rows = try PostgRESTDate.decoder.decode([SixAllowance].self, from: data)
        #expect(rows[0].left == 0)
        #expect(rows[0].nextAt != nil)
        #expect(rows[1] == SixAllowance(left: 2, nextAt: nil))
    }

    @Test("the 6 is explained once per person, and survives a relaunch")
    @MainActor
    func toldOnce() {
        let store = InMemoryKeyValueStore()
        let me = UUID()
        let preferences = AtePreferences(store: store)
        #expect(preferences.owesSixFound(me))
        #expect(preferences.owesSixFound(nil) == false)
        preferences.toldSixFound(me)
        #expect(preferences.owesSixFound(me) == false)
        #expect(AtePreferences(store: store).owesSixFound(me) == false)
    }

    @Test("the locked slider and the explainer are counted")
    func events() {
        #expect(EntryEvents.scoreSixLocked().name == "entry_score_six_locked")
        #expect(EntryEvents.sixExplained().name == "entry_six_explained")
    }
}
